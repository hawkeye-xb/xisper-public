/**
 * ASR WebSocket Proxy — Adapter Architecture
 *
 * Accepts a simplified protocol from the frontend:
 *   Client → Proxy: text {"type":"start","config":{...}} → binary PCM → text {"type":"finish"}
 *   Proxy → Client: text JSON (NormalizedASREvent compatible with ASRResult)
 *
 * Internally routes to the best available ASR provider via adapters,
 * with automatic connection-level fallback.
 */

import type { Context } from 'hono';
import { resolveToken, verifyJWT } from '../middlewares/auth';
import { checkASRQuota, fetchCustomLimits } from '../utils/rate-limiter';
import { generateSessionId } from '../utils/ws-session';
import { resolveUserTier } from '../utils/subscription';
import { normalizeTier, type UserTier, type CustomQuotaLimits } from '../config/rate-limits';

import type { ASRProviderAdapter } from '../asr/types';
import type { ASRSessionConfig, NormalizedASREvent, NormalizedUtterance } from '../asr/types';
import { createASRAdapter } from '../asr/adapter-factory';

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

type Bindings = {
  AI_KV: KVNamespace;
  DB: D1Database;
  AI_WORKER: Fetcher;
  LOGTO_ENDPOINT: string;
  LOGTO_APP_ID?: string;
  DOUBAO_APP_ID?: string;
  DOUBAO_ACCESS_TOKEN?: string;
  DOUBAO_RESOURCE_ID?: string;
  DOUBAO_CLUSTER?: string;
  ALIBABA_API_KEY?: string;
  ALIBABA_VOCABULARY_ID?: string;
  ASR_MODEL?: string;
  SONIOX_API_KEY?: string;
  ENVIRONMENT?: string;
};

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

export async function handleASRWebSocket(c: Context<{ Bindings: Bindings }>) {
  const upgradeHeader = c.req.header('Upgrade');
  if (!upgradeHeader || upgradeHeader !== 'websocket') {
    return c.text('Expected WebSocket', 426);
  }

  // Authenticate
  const token = resolveToken(c);
  if (!token) {
    console.log('[ASR Proxy] Missing authentication token');
    return c.text('Missing authentication token', 401);
  }

  let jwtPayload: { sub: string; email?: string };
  try {
    const verified = await verifyJWT(token, c.env);
    jwtPayload = { sub: verified.sub, email: verified.email };
  } catch (error: any) {
    console.log('[ASR Proxy] Token verification failed:', error.message);
    return c.text('Invalid authentication token', 401);
  }

  const userId = jwtPayload.sub;
  console.log('[ASR Proxy] Token verified, user:', userId);

  // Ensure user exists
  let user = await c.env.DB.prepare('SELECT tier FROM users WHERE id = ?').bind(userId).first();
  if (!user) {
    const now = Date.now();
    await c.env.DB.prepare(
      'INSERT INTO users (id, email, tier, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
    )
      .bind(userId, jwtPayload.email || `${userId}@unknown.com`, 'free', now, now)
      .run();
    console.log('[ASR Proxy] Created new user:', userId);
  }

  // Resolve effective tier — cross-checks subscription validity
  const userTier = await resolveUserTier(c.env.DB, userId);
  const customLimits = await fetchCustomLimits(c.env.AI_KV, userId);

  // Quota check
  const quotaCheck = await checkASRQuota(c.env.AI_KV, userId, userTier, customLimits, c.env.DB);
  if (!quotaCheck.duration.allowed || !quotaCheck.characters.allowed) {
    const reason = !quotaCheck.duration.allowed
      ? `Duration limit exceeded: ${quotaCheck.duration.current}/${quotaCheck.duration.limit} seconds`
      : `Character limit exceeded: ${quotaCheck.characters.current}/${quotaCheck.characters.limit} characters`;
    console.log(`[ASR Proxy] Quota exceeded for user ${userId}: ${reason}`);
    return c.text(reason, 429);
  }

  // Create WebSocket pair
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  const sessionId = generateSessionId();

  // Extract geo info from CF request metadata for ASR geo-routing.
  const clientCountry = (c.req.raw.cf as any)?.country as string | undefined;

  c.executionCtx.waitUntil(
    handleASRProxyConnection(server as WebSocket, c.env, userId, userTier, sessionId, c.executionCtx, customLimits, clientCountry),
  );

  return new Response(null, { status: 101, webSocket: client });
}

// ---------------------------------------------------------------------------
// Connection handler
// ---------------------------------------------------------------------------

async function handleASRProxyConnection(
  clientWS: WebSocket,
  env: Bindings,
  userId: string,
  userTier: UserTier,
  sessionId: string,
  executionCtx: ExecutionContext,
  customLimits?: CustomQuotaLimits | null,
  country?: string,
): Promise<void> {
  let asrWS: WebSocket | null = null;
  let activeAdapter: ASRProviderAdapter | null = null;
  let heartbeatInterval: ReturnType<typeof setInterval> | null = null;
  let lastActivityTime = Date.now();
  let recordingId: string | null = null;

  // Metrics
  const sessionStartTime = Date.now();
  let totalCharCount = 0;
  let resultEventsCount = 0;
  let firstAudioTime: number | null = null;
  let firstTextResponseTime: number | null = null;

  // Incremental quota consumption — chars per definitive segment, duration every 30s.
  // Decoupled from clientWS close so quota is consumed even if client disconnects abruptly.
  let lastConsumedCharTotal = 0;
  let lastConsumedDurationSec = 0;
  let durationTimerId: ReturnType<typeof setInterval> | null = null;

  // Message buffer (PCM binary frames arriving before upstream is ready).
  // No size limit — a transparent proxy must never drop audio frames.
  // At 32KB/s (16kHz×16bit×mono), even 60s of buffering is only ~1.9MB.
  const messageBuffer: ArrayBuffer[] = [];
  let isBuffering = true;
  const bufferStats = { maxSize: 0, totalBuffered: 0 };

  // Tracks when audio first started flowing to upstream (after flush or direct forward).
  // Used with adapter.minAudioFlowBeforeFinishMs to delay finish for burst-delivered audio.
  let upstreamAudioFlowStart: number | null = null;

  // Graceful shutdown tracking
  let clientSentFinish = false;
  let finishSentToUpstream = false;
  let receivedAsrFinal = false;
  let asrFinalResolve: (() => void) | null = null;
  let asrCloseTimeoutId: ReturnType<typeof setTimeout> | null = null;

  // Session lifetime promise
  let sessionResolve: () => void;
  const sessionComplete = new Promise<void>((resolve) => {
    sessionResolve = resolve;
  });

  console.log(`[ASR Proxy] Session started: ${sessionId} for user ${userId}, country=${country || 'unknown'} (recordingId will be set on start config)`);

  // Step 1 — Accept client immediately
  clientWS.accept();

  // Step 2 — Listen for client messages
  // First text frame = start config, subsequent binary = PCM audio, final text = finish
  let startConfigReceived = false;
  let startConfigResolve: ((config: ASRSessionConfig) => void) | null = null;
  const startConfigPromise = new Promise<ASRSessionConfig>((resolve) => {
    startConfigResolve = resolve;
  });

  clientWS.addEventListener('message', async (event) => {
    lastActivityTime = Date.now();

    if (typeof event.data === 'string') {
      // Text frame — either start or finish
      try {
        const msg = JSON.parse(event.data);

        if (msg.type === 'start' && !startConfigReceived) {
          startConfigReceived = true;

          // Identity is the single source of truth: when identityId is set, KV overrides
          // identityHotwords and vocabularyId, ignoring whatever client sent.
          let resolvedIdentityHotwords: string[] | undefined = Array.isArray(msg.config?.identityHotwords)
            ? msg.config.identityHotwords : undefined;
          let resolvedVocabularyId: string | undefined = msg.config?.vocabularyId;
          const identityId: string | undefined = msg.config?.identityId;

          if (identityId) {
            try {
              const kvData = await env.AI_KV.get(`identity:${identityId}`, 'json') as any;
              if (kvData) {
                if (Array.isArray(kvData.hotwords)) {
                  resolvedIdentityHotwords = kvData.hotwords.map((h: any) => typeof h === 'string' ? h : h.text).filter(Boolean);
                } else {
                  resolvedIdentityHotwords = [];
                }
                if (typeof kvData.vocabularyId === 'string' && kvData.vocabularyId) {
                  resolvedVocabularyId = kvData.vocabularyId;
                }
                console.log(`[ASR Proxy] Identity override from KV: id=${identityId}, hotwords=${resolvedIdentityHotwords?.length ?? 0}, vocabularyId=${resolvedVocabularyId || '<none>'}`);
              }
            } catch (e) {
              console.warn(`[ASR Proxy] KV lookup for identity:${identityId} failed:`, (e as Error).message);
            }
          }

          const cfg: ASRSessionConfig = {
            language: msg.config?.language || 'zh-CN',
            enableITN: msg.config?.enableITN ?? true,
            enablePunctuation: msg.config?.enablePunctuation ?? true,
            enableSmoothing: msg.config?.enableSmoothing ?? true,
            sampleRate: msg.config?.sampleRate || 16000,
            format: msg.config?.format || 'pcm',
            vocabularyId: resolvedVocabularyId || env.ALIBABA_VOCABULARY_ID || undefined,
            hotwords: Array.isArray(msg.config?.hotwords) ? msg.config.hotwords : undefined,
            identityHotwords: resolvedIdentityHotwords,
            identityId,
            semanticPunctuationEnabled: msg.config?.semanticPunctuationEnabled ?? true,
            maxSentenceSilence: msg.config?.maxSentenceSilence,
            multiThresholdModeEnabled: msg.config?.multiThresholdModeEnabled,
            recordingId: msg.config?.recordingId || undefined,
            retranscribe: msg.config?.retranscribe ?? false,
          };
          recordingId = cfg.recordingId || null;
          startConfigResolve?.(cfg);
          return;
        }

        if (msg.type === 'finish') {
          clientSentFinish = true;
          console.log('[ASR Proxy] Client sent finish');
          if (!isBuffering && !finishSentToUpstream && activeAdapter && asrWS && asrWS.readyState === WebSocket.OPEN) {
            try {
              activeAdapter.sendFinish(asrWS);
              finishSentToUpstream = true;
            } catch (e) {
              console.error('[ASR Proxy] Error sending finish to upstream:', e);
            }
          } else {
            console.log('[ASR Proxy] Finish will be deferred (isBuffering=%s)', isBuffering);
          }
          return;
        }
      } catch {
        // Not valid JSON — ignore
      }
      return;
    }

    // Binary frame — raw PCM audio
    if (!firstAudioTime) firstAudioTime = Date.now();

    if (isBuffering) {
      messageBuffer.push(event.data as ArrayBuffer);
      bufferStats.totalBuffered++;
      if (messageBuffer.length > bufferStats.maxSize) bufferStats.maxSize = messageBuffer.length;
    } else {
      // Direct forwarding via adapter
      if (activeAdapter && asrWS && asrWS.readyState === WebSocket.OPEN) {
        try {
          if (!upstreamAudioFlowStart) upstreamAudioFlowStart = Date.now();
          activeAdapter.sendAudio(asrWS, event.data as ArrayBuffer);
        } catch (e) {
          console.error('[ASR Proxy] Error forwarding audio:', e);
        }
      }
    }
  });

  try {
    // Step 3 — Wait for client start config (with timeout)
    let startConfigTimeoutId: ReturnType<typeof setTimeout> | null = null;
    const sessionConfig = await Promise.race([
      startConfigPromise,
      new Promise<never>((_, reject) => {
        startConfigTimeoutId = setTimeout(
          () => reject(new Error('Timeout waiting for start config')),
          15000,
        );
      }),
    ]);
    if (startConfigTimeoutId) { clearTimeout(startConfigTimeoutId); startConfigTimeoutId = null; }

    console.log(`[ASR Proxy] Received start config: recordingId=${recordingId || 'none'}`, JSON.stringify(sessionConfig));

    // Step 3.5 — Async file transcription for retranscribe.
    // Client sends retranscribe:true when re-transcribing a saved recording.
    // If the adapter supports transcribeFile (e.g. Soniox Async API),
    // wait for all audio + finish, then use the async file API.
    // No delay for normal recordings — they go straight to real-time WebSocket.
    const adapter = createASRAdapter(env, country);

    if (sessionConfig.retranscribe && adapter.transcribeFile) {
      console.log(`[ASR Proxy] Retranscribe mode with ${adapter.name} async file transcription`);

      // Wait for client to send all audio + finish
      await new Promise<void>((resolve) => {
        if (clientSentFinish) { resolve(); return; }
        const iv = setInterval(() => {
          if (clientSentFinish) { clearInterval(iv); resolve(); }
        }, 50);
        // Safety timeout: 30s max wait for client to finish sending
        setTimeout(() => { clearInterval(iv); resolve(); }, 30000);
      });

      isBuffering = false;
      sendToClient(clientWS, { type: 'started', code: 20000000, provider: adapter.name });

      // Merge buffered PCM
      const totalBytes = messageBuffer.reduce((sum, buf) => sum + buf.byteLength, 0);
      const merged = new Uint8Array(totalBytes);
      let mergeOffset = 0;
      for (const buf of messageBuffer) {
        merged.set(new Uint8Array(buf), mergeOffset);
        mergeOffset += buf.byteLength;
      }
      messageBuffer.length = 0;

      console.log(`[ASR Proxy] Retranscribe: ${totalBytes} bytes PCM, sending to ${adapter.name} async API`);
      const wavData = buildWav(merged.buffer, sessionConfig.sampleRate || 16000, 1);

      try {
        const text = await adapter.transcribeFile(env, wavData, sessionConfig);
        receivedAsrFinal = true;
        const charStats = calculateCharacterCount(text);
        totalCharCount = charStats.count;
        console.log(`[ASR Proxy] Async transcription done (${charStats.count} chars)`);

        sendToClient(clientWS, {
          type: 'result', code: 20000000, is_last_package: false,
          result: { text, utterances: [{ text, definite: true }] },
          provider: adapter.name,
        });
        sendToClient(clientWS, {
          type: 'finished', code: 20000000, is_last_package: true,
          result: { text, utterances: [{ text, definite: true }] },
          provider: adapter.name,
        });

        // Consume quota via AI_WORKER
        const durationSec = Math.max(1, Math.floor(totalBytes / 32000));
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'consume_duration', userId, amount: durationSec, tier: userTier,
        });
        if (totalCharCount > 0) {
          offloadMetering(env.AI_WORKER, executionCtx, {
            action: 'consume_characters', userId, amount: totalCharCount, tier: userTier,
          });
        }
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'audit', userId, amount: durationSec, tier: userTier,
          metadata: { metric: 'duration', sessionId, recordingId, adapter: adapter.name, mode: 'async-file' },
        });
      } catch (e: any) {
        console.error(`[ASR Proxy] Async file transcription failed:`, e.message);
        sendToClient(clientWS, { type: 'error', is_last_package: true, error: e.message, provider: adapter.name });
      }

      try { clientWS.close(1000, 'Normal closure'); } catch { /* ignore */ }
      sessionResolve!();
      await sessionComplete;
      return;
    }
    const MAX_CONNECT_RETRIES = 2;

    for (let attempt = 1; attempt <= MAX_CONNECT_RETRIES; attempt++) {
      try {
        console.log(`[ASR Proxy] Connecting to ${adapter.name} (attempt ${attempt}/${MAX_CONNECT_RETRIES})`);

        // createConnection may return a Promise (fetch upgrade) or WebSocket
        const wsOrPromise = adapter.createConnection(env);
        asrWS = wsOrPromise instanceof Promise ? await wsOrPromise : wsOrPromise;

        // fetch-upgrade returns an already-open WebSocket; standard constructor needs to wait
        if (asrWS.readyState !== WebSocket.OPEN) {
          await new Promise<void>((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('Connection timeout')), 8000);
            asrWS!.addEventListener('open', () => { clearTimeout(timeout); resolve(); });
            asrWS!.addEventListener('error', () => { clearTimeout(timeout); reject(new Error('Connection error')); });
          });
        }

        console.log(`[ASR Proxy] ${adapter.name} connected, sending init`);
        adapter.sendInit(asrWS, sessionConfig);

        // Wait for task-started before sending audio.
        // Adapters with immediateReady=true (e.g. Soniox) are ready right after sendInit.
        if (adapter.immediateReady) {
          console.log(`[ASR Proxy] ${adapter.name} immediateReady — skipping handshake wait`);
          sendToClient(clientWS, { type: 'started', code: 20000000, provider: adapter.name });
        } else {
          await new Promise<void>((resolve, reject) => {
            const timeout = setTimeout(
              () => reject(new Error('Timeout waiting for task-started')),
              8000,
            );
            const onMsg = (ev: MessageEvent) => {
              const parsed = adapter.parseResponse(ev.data);
              if (parsed && adapter.isReady(parsed)) {
                clearTimeout(timeout);
                asrWS!.removeEventListener('message', onMsg);
                sendToClient(clientWS, { type: 'started', code: 20000000, provider: adapter.name });
                resolve();
              }
              if (parsed && parsed.type === 'error') {
                clearTimeout(timeout);
                asrWS!.removeEventListener('message', onMsg);
                reject(new Error(parsed.error || 'ASR init error'));
              }
            };
            asrWS!.addEventListener('message', onMsg);
          });
        }

        activeAdapter = adapter;
        console.log(`[ASR Proxy] Using adapter: ${adapter.name}`);
        break;
      } catch (e: any) {
        console.warn(`[ASR Proxy] ${adapter.name} attempt ${attempt} failed: ${e.message}`);
        if (asrWS) {
          try { asrWS.close(); } catch { /* ignore */ }
          asrWS = null;
        }
        if (attempt < MAX_CONNECT_RETRIES) {
          await new Promise((r) => setTimeout(r, 300));
        }
      }
    }

    if (!activeAdapter || !asrWS) {
      throw new Error(`ASR connection failed after ${MAX_CONNECT_RETRIES} attempts`);
    }

    // Step 5 — Flush buffered audio to upstream.
    //
    // Burst detection: if client already sent finish while we were still buffering,
    // ALL audio arrived before the upstream was ready. This is a retranscribe / retry.
    // Adapters like Soniox require real-time pacing on WebSocket, so burst-flushing
    // causes disconnection. If the adapter supports async file transcription
    // (transcribeFile), bypass the real-time WebSocket entirely.
    // --- Standard real-time WebSocket flush path ---
    if (messageBuffer.length > 0) {
      console.log(`[ASR Proxy] Flushing ${messageBuffer.length} buffered PCM frames`);
      for (const pcm of messageBuffer) {
        if (asrWS.readyState === WebSocket.OPEN) {
          try {
            if (!upstreamAudioFlowStart) upstreamAudioFlowStart = Date.now();
            activeAdapter.sendAudio(asrWS, pcm);
          } catch (e) {
            console.error('[ASR Proxy] Error flushing buffered frame:', e);
          }
        }
      }
      messageBuffer.length = 0;
    }
    isBuffering = false;
    console.log('[ASR Proxy] Switched to direct forwarding');

    // Send deferred finish if client already requested it while upstream was connecting.
    // Respect adapter.minAudioFlowBeforeFinishMs: if audio was burst-flushed, the
    // upstream VAD may need real-time-scale processing before finish terminates it.
    if (clientSentFinish && !finishSentToUpstream) {
      const minFlow = activeAdapter.minAudioFlowBeforeFinishMs ?? 0;
      if (minFlow > 0 && upstreamAudioFlowStart) {
        const elapsed = Date.now() - upstreamAudioFlowStart;
        if (elapsed < minFlow) {
          const padMs = minFlow - elapsed;
          console.log(`[ASR Proxy] Padding finish by ${padMs}ms (adapter min=${minFlow}ms, elapsed=${elapsed}ms)`);
          await new Promise((r) => setTimeout(r, padMs));
        }
      }
      try {
        activeAdapter.sendFinish(asrWS);
        finishSentToUpstream = true;
        console.log('[ASR Proxy] Sent deferred finish to upstream');
      } catch (e) {
        console.error('[ASR Proxy] Error sending deferred finish:', e);
      }
    }

    // Step 6 — Heartbeat + periodic duration consumption
    heartbeatInterval = setInterval(() => {
      const idleTime = Date.now() - lastActivityTime;
      if (idleTime > 30000) {
        if (clientWS.readyState === WebSocket.OPEN && asrWS && asrWS.readyState === WebSocket.OPEN) {
          try {
            clientWS.send(new ArrayBuffer(0));
            lastActivityTime = Date.now();
          } catch { /* ignore */ }
        }
      }
    }, 30000);

    // Periodic duration consumption — every 30s, offload to AI_WORKER.
    durationTimerId = setInterval(() => {
      const elapsed = Math.floor((Date.now() - sessionStartTime) / 1000);
      const delta = elapsed - lastConsumedDurationSec;
      if (delta > 0) {
        lastConsumedDurationSec = elapsed;
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'consume_duration', userId, amount: delta, tier: userTier,
        });
        console.log(`[ASR Proxy] Duration increment offloaded: +${delta}s (total ${elapsed}s)`);
      }
    }, 30000);

    // Step 7 — Forward upstream responses → client (with text accumulation)
    const currentAdapter = activeAdapter;

    // Accumulation state — normalizes per-segment providers (Alibaba) to
    // always send the full accumulated picture, matching the protocol that
    // accumulating providers (Doubao) already use.
    const acc = {
      definiteUtterances: [] as NormalizedUtterance[],
      definiteText: '',
    };

    /** Consume character quota for newly confirmed text (delta since last consumption). */
    function consumeCharIncrement() {
      const currentTotal = calculateCharacterCount(acc.definiteText).count;
      const delta = currentTotal - lastConsumedCharTotal;
      if (delta > 0) {
        lastConsumedCharTotal = currentTotal;
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'consume_characters', userId, amount: delta, tier: userTier,
        });
        console.log(`[ASR Proxy] Char increment offloaded: +${delta} (total ${currentTotal})`);
      }
    }

    asrWS.addEventListener('message', (event) => {
      lastActivityTime = Date.now();
      try {
        const parsed = currentAdapter.parseResponse(event.data);
        if (!parsed) return;

        let outEvent: NormalizedASREvent = parsed;

        // --- Accumulate / normalise result events ---
        if (parsed.type === 'result' && parsed.result) {
          if (currentAdapter.accumulatesResults) {
            // Provider already sends the full picture — track for finished enrichment
            if (parsed.result.text) acc.definiteText = parsed.result.text;
            if (parsed.result.utterances) {
              const definite = parsed.result.utterances.filter(u => u.definite);
              if (definite.length > 0) {
                acc.definiteUtterances = definite;
              }
            }
          } else {
            // Provider sends per-segment — accumulate at proxy
            const utterances = parsed.result.utterances || [];
            for (const u of utterances) {
              if (u.definite) {
                acc.definiteUtterances.push({ ...u });
                acc.definiteText += u.text;
              }
            }
            const pending = utterances.filter(u => !u.definite);
            const pendingText = pending.map(u => u.text).join('');

            outEvent = {
              type: 'result',
              code: parsed.code,
              is_last_package: false,
              result: {
                text: acc.definiteText + pendingText,
                utterances: [...acc.definiteUtterances, ...pending],
              },
              provider: parsed.provider,
            };
          }

          // Consume character quota for newly confirmed definitive segments
          consumeCharIncrement();
        }

        // --- Track result events and first text response latency ---
        if (parsed.type === 'result') {
          resultEventsCount++;
        }
        if (!firstTextResponseTime && outEvent.result?.text) {
          firstTextResponseTime = Date.now();
          const latency = firstAudioTime ? firstTextResponseTime - firstAudioTime : null;
          console.log(`[ASR Proxy] First text response latency: ${latency}ms`);
        }

        // --- Handle finished: enrich with accumulated text + settle remaining quota ---
        if (currentAdapter.isFinished(parsed)) {
          receivedAsrFinal = true;
          asrFinalResolve?.();

          if (!parsed.result?.text && acc.definiteText) {
            outEvent = {
              ...parsed,
              result: {
                text: acc.definiteText,
                utterances: acc.definiteUtterances.length > 0
                  ? [...acc.definiteUtterances]
                  : undefined,
              },
            };
          }

          const text = outEvent.result?.text;
          if (text) {
            const charStats = calculateCharacterCount(text);
            console.log(
              `[ASR Proxy] Final text: "${text}" — chars: ${charStats.count} (zh: ${charStats.details.chinese}, en: ${charStats.details.english})`,
            );
            totalCharCount += charStats.count;
          }

          // Settle remaining character quota (delta between final total and already-consumed)
          const finalCharTotal = totalCharCount;
          const charRemaining = finalCharTotal - lastConsumedCharTotal;

          // Settle remaining duration quota
          const finalDuration = Math.floor((Date.now() - sessionStartTime) / 1000);
          const durationRemaining = finalDuration - lastConsumedDurationSec;

          // Stop periodic duration timer — session is done
          if (durationTimerId) { clearInterval(durationTimerId); durationTimerId = null; }

          // Fire-and-forget: offload remaining quota + audit to AI_WORKER
          if (charRemaining > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'consume_characters', userId, amount: charRemaining, tier: userTier,
            });
          }
          if (durationRemaining > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'consume_duration', userId, amount: durationRemaining, tier: userTier,
            });
          }
          if (finalDuration > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'audit', userId, amount: finalDuration, tier: userTier,
              metadata: { metric: 'duration', sessionId, recordingId, adapter: currentAdapter.name },
            });
          }
          if (finalCharTotal > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'audit', userId, amount: finalCharTotal, tier: userTier,
              metadata: { metric: 'characters', sessionId, recordingId, adapter: currentAdapter.name, countMethod: 'language-aware', bufferStats },
            });
          }
          console.log(`[ASR Proxy] Quota settlement offloaded: chars=${finalCharTotal} (remaining=${charRemaining}), duration=${finalDuration}s (remaining=${durationRemaining}s)`);

          // Attach metadata so the client can distinguish "no speech" from "service error"
          (outEvent as any).meta = { resultEventsCount };
        }

        sendToClient(clientWS, outEvent);
      } catch (e) {
        console.error('[ASR Proxy] Error processing upstream message:', e);
      }
    });

    // Step 8 — Handle close / error
    clientWS.addEventListener('error', (event) => {
      console.error('[ASR Proxy] Client WS error:', event);
    });
    asrWS.addEventListener('error', (event) => {
      // Serialize the event so CF Logs doesn't render `[object Object]` and lose context.
      const detail = serializeWSEventForLog(event);
      console.error(`[ASR Proxy] Upstream WS error: ${detail}`);
    });

    let clientCloseInitiated = false;
    let cleanupCalled = false;

    clientWS.addEventListener('close', (event) => {
      if (clientCloseInitiated) return;
      clientCloseInitiated = true;
      // Do NOT call sessionResolve here. sessionComplete must resolve only after asrWS is fully
      // closed — otherwise Cloudflare sees waitUntil done while there is still an outbound
      // WebSocket in CLOSING state, and reports "code had hung".
      // sessionResolve is called by the asrWS.close handler (or by cleanup if asrWS is gone).
      console.log(
        `[ASR Proxy] Client close: code=${event.code}, clientSentFinish=${clientSentFinish}, receivedAsrFinal=${receivedAsrFinal}`,
      );

      // If finish was never forwarded to upstream, do it now
      if (!finishSentToUpstream && activeAdapter && asrWS && asrWS.readyState === WebSocket.OPEN) {
        try {
          activeAdapter.sendFinish(asrWS);
          finishSentToUpstream = true;
          console.log('[ASR Proxy] Sent finish to upstream on behalf of client');
        } catch { /* ignore */ }
      }

      // Fire-and-forget: do not await. sessionResolve is called by asrWS.close after upstream acks.
      if (!receivedAsrFinal && asrWS && asrWS.readyState === WebSocket.OPEN) {
        console.log('[ASR Proxy] Waiting for upstream final...');
        Promise.race([
          new Promise<void>((resolve) => { asrFinalResolve = resolve; }),
          new Promise<void>((resolve) => setTimeout(resolve, 5000)),
        ]).then(() => void cleanup());
      } else {
        void cleanup();
      }
    });

    asrWS.addEventListener('close', (event) => {
      // Clear safety timeout if it was set by cleanup()
      if (asrCloseTimeoutId) { clearTimeout(asrCloseTimeoutId); asrCloseTimeoutId = null; }
      // Upstream is fully closed — NOW it is safe to unblock waitUntil
      sessionResolve!();
      // Full event serialization (code/reason/wasClean/type) so we can tell whether
      // upstream closed cleanly or aborted, and what reason text (if any) it sent.
      console.log(`[ASR Proxy] Upstream close: ${serializeWSEventForLog(event)}`);
      void cleanup(event.code, event.reason);
    });

    // Cleanup — connection teardown + refund if upstream disconnected without final
    async function cleanup(asrCloseCode?: number, asrCloseReason?: string) {
      if (cleanupCalled) return;
      cleanupCalled = true;

      if (heartbeatInterval) { clearInterval(heartbeatInterval); heartbeatInterval = null; }
      if (durationTimerId) { clearInterval(durationTimerId); durationTimerId = null; }

      // Diagnostic: anomaly — Soniox closed but never sent `finished:true`.
      // Surface the accumulated text + close metadata + result event count so we can
      // verify whether identification was actually completed (and just missing the
      // final ack) or genuinely aborted upstream.
      if (!receivedAsrFinal && finishSentToUpstream) {
        const accPreview = (acc.definiteText || '').substring(0, 300);
        console.warn(
          `[ASR Proxy] ANOMALY: upstream closed without finished. ` +
          `clientSentFinish=${clientSentFinish} clientCloseInitiated=${clientCloseInitiated} ` +
          `closeCode=${asrCloseCode} closeReason="${asrCloseReason || ''}" ` +
          `resultEvents=${resultEventsCount} accLen=${(acc.definiteText || '').length} ` +
          `accPreview="${accPreview}"`
        );
      }

      // Refund quota if upstream disconnected before delivering a final result
      // and the client did NOT initiate the close (i.e. upstream dropped us).
      if (!receivedAsrFinal && !clientCloseInitiated) {
        const refundChars = lastConsumedCharTotal;
        const refundDuration = lastConsumedDurationSec;
        if (refundChars > 0 || refundDuration > 0) {
          console.log(`[ASR Proxy] Upstream disconnect without final — refunding chars=${refundChars}, duration=${refundDuration}s`);
          if (refundChars > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'refund_characters', userId, amount: refundChars, tier: userTier,
            });
          }
          if (refundDuration > 0) {
            offloadMetering(env.AI_WORKER, executionCtx, {
              action: 'refund_duration', userId, amount: refundDuration, tier: userTier,
            });
          }
          offloadMetering(env.AI_WORKER, executionCtx, {
            action: 'audit', userId, amount: refundDuration + refundChars, tier: userTier,
            metadata: { type: 'refund', metric: 'upstream_disconnect', sessionId, recordingId, adapter: activeAdapter?.name, refundChars, refundDuration, asrCloseCode, asrCloseReason },
          });
        }
      }

      if (asrWS && asrWS.readyState === WebSocket.OPEN) {
        asrWS.close(1000, 'Normal closure');
        asrCloseTimeoutId = setTimeout(() => {
          asrCloseTimeoutId = null;
          console.warn('[ASR Proxy] Upstream close ack timeout, force resolving session');
          sessionResolve!();
        }, 8000);
      } else {
        sessionResolve!();
      }

      try { clientWS.close(asrCloseCode || 1000, asrCloseReason || 'Normal closure'); } catch { /* ignore */ }

      const durationMs = Date.now() - sessionStartTime;
      const firstTextLatencyMs = firstAudioTime && firstTextResponseTime
        ? firstTextResponseTime - firstAudioTime : null;

      console.log('[ASR Proxy] Session closed:', {
        adapter: activeAdapter?.name,
        duration: `${Math.floor(durationMs / 1000)}s`,
        chars: totalCharCount,
        consumedChars: lastConsumedCharTotal,
        consumedDuration: lastConsumedDurationSec,
        receivedAsrFinal,
        firstTextLatencyMs,
        bufferStats,
      });
    }
  } catch (error: any) {
    console.error('[ASR Proxy] Connection error:', error.message || error);

    if (heartbeatInterval) clearInterval(heartbeatInterval);
    if (durationTimerId) clearInterval(durationTimerId);
    if (asrWS) { try { asrWS.close(); } catch { /* ignore */ } }

    // Refund consumed quota on connection failure (upstream never delivered final)
    if (!receivedAsrFinal && (lastConsumedCharTotal > 0 || lastConsumedDurationSec > 0)) {
      const refundChars = lastConsumedCharTotal;
      const refundDuration = lastConsumedDurationSec;
      console.log(`[ASR Proxy] Connection error — refunding chars=${refundChars}, duration=${refundDuration}s`);
      if (refundChars > 0) {
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'refund_characters', userId, amount: refundChars, tier: userTier,
        });
      }
      if (refundDuration > 0) {
        offloadMetering(env.AI_WORKER, executionCtx, {
          action: 'refund_duration', userId, amount: refundDuration, tier: userTier,
        });
      }
      offloadMetering(env.AI_WORKER, executionCtx, {
        action: 'audit', userId, amount: refundDuration + refundChars, tier: userTier,
        metadata: { type: 'refund', metric: 'connection_error', sessionId, recordingId, adapter: activeAdapter?.name, refundChars, refundDuration, error: error.message },
      });
    }

    // Send error to client before closing
    sendToClient(clientWS, {
      type: 'error',
      is_last_package: true,
      error: error.message || 'ASR proxy error',
      provider: activeAdapter?.name || 'none',
    });

    if (clientWS.readyState === WebSocket.OPEN) {
      clientWS.close(1011, 'Internal server error');
    }

    messageBuffer.length = 0;
    sessionResolve!();
  }

  await sessionComplete;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sendToClient(ws: WebSocket, event: NormalizedASREvent) {
  if (ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(JSON.stringify(event));
  } catch { /* ignore */ }
}

/**
 * Serialize a CloseEvent / ErrorEvent for CF Logs. Without this, console.log
 * renders as `[object Object]` and we lose context on close reasons.
 */
function serializeWSEventForLog(event: any): string {
  if (!event) return 'null';
  const fields: Record<string, any> = {};
  for (const k of ['code', 'reason', 'wasClean', 'type', 'message', 'error']) {
    if (event[k] !== undefined) fields[k] = event[k];
  }
  // Some runtimes attach `error` as an Error instance; capture name + message + stack.
  if (event.error && typeof event.error === 'object') {
    fields.error = {
      name: (event.error as Error).name,
      message: (event.error as Error).message,
      stack: ((event.error as Error).stack || '').substring(0, 400),
    };
  }
  try { return JSON.stringify(fields); } catch { return String(event); }
}

/**
 * Fire-and-forget metering via AI_WORKER service binding.
 * Each call triggers a new Worker invocation with its own CPU budget.
 */
function offloadMetering(
  aiWorker: Fetcher,
  executionCtx: ExecutionContext,
  payload: {
    action: 'consume_duration' | 'consume_characters' | 'refund_duration' | 'refund_characters' | 'consume_llm' | 'audit';
    userId: string;
    amount: number;
    tier: string;
    metadata?: Record<string, any>;
  },
) {
  executionCtx.waitUntil(
    aiWorker.fetch(new Request('https://ai-worker/v1/metering', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })).then((res) => {
      if (!res.ok) console.warn(`[Metering] offload ${payload.action} failed: ${res.status}`);
    }).catch((e) => console.warn(`[Metering] offload ${payload.action} error:`, (e as Error).message)),
  );
}

// Pre-compiled regex for CJK character matching (avoids re-compilation per call)
const CJK_REGEX =
  /[\u4e00-\u9fff\u3400-\u4dbf\u{20000}-\u{2a6df}\u{2a700}-\u{2b73f}\u{2b740}-\u{2b81f}\u{2b820}-\u{2ceaf}\uf900-\ufaff\u3040-\u309f\u30a0-\u30ff\uac00-\ud7af]/gu;

function calculateCharacterCount(
  text: string,
): { count: number; details: { chinese: number; english: number; other: number } } {
  if (!text) return { count: 0, details: { chinese: 0, english: 0, other: 0 } };

  CJK_REGEX.lastIndex = 0;
  const cjkMatches = text.match(CJK_REGEX) || [];
  const cjkCount = cjkMatches.length;

  CJK_REGEX.lastIndex = 0;
  const nonCjkText = text.replace(CJK_REGEX, '');
  const words = nonCjkText
    .split(/\s+/)
    .filter((w) => w.trim().length > 0 && /[a-zA-Z0-9]/.test(w));
  const wordCount = words.length;

  const otherChars = nonCjkText.replace(/\s+/g, '').replace(/[a-zA-Z0-9]+/g, '').length;

  return {
    count: cjkCount + wordCount,
    details: { chinese: cjkCount, english: wordCount, other: otherChars },
  };
}

/**
 * Build a minimal WAV container from raw PCM data.
 * Used by the async file transcription path to wrap PCM for upload.
 */
function buildWav(pcm: ArrayBuffer, sampleRate: number, numChannels: number): ArrayBuffer {
  const bitsPerSample = 16;
  const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
  const blockAlign = numChannels * (bitsPerSample / 8);
  const dataSize = pcm.byteLength;
  const headerSize = 44;

  const buffer = new ArrayBuffer(headerSize + dataSize);
  const view = new DataView(buffer);

  // RIFF header
  writeString(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, 'WAVE');

  // fmt chunk
  writeString(view, 12, 'fmt ');
  view.setUint32(16, 16, true); // chunk size
  view.setUint16(20, 1, true);  // PCM format
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);

  // data chunk
  writeString(view, 36, 'data');
  view.setUint32(40, dataSize, true);

  // PCM data
  new Uint8Array(buffer, headerSize).set(new Uint8Array(pcm));

  return buffer;
}

function writeString(view: DataView, offset: number, str: string) {
  for (let i = 0; i < str.length; i++) {
    view.setUint8(offset + i, str.charCodeAt(i));
  }
}
