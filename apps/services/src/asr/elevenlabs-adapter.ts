/**
 * ElevenLabs Scribe v2 Realtime ASR Adapter
 *
 * Protocol: WebSocket with JSON text frames (base64-encoded PCM audio).
 * Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
 *
 * Key features:
 *   - ~150ms latency with Scribe v2 Realtime
 *   - Keyterm prompting (hotwords): max 50 terms, 20 chars each, +$0.05/hr
 *   - Partial transcripts (interim results) + committed transcripts (final)
 *   - Optional word-level timestamps
 */

import type {
  ASRProviderAdapter,
  ASRSessionConfig,
  NormalizedASREvent,
  NormalizedUtterance,
} from './types';

const ELEVENLABS_WSS = 'https://api.elevenlabs.io/v1/speech-to-text/realtime';
const ELEVENLABS_FILE_API = 'https://api.elevenlabs.io/v1/speech-to-text';

/** Max keyterms supported by ElevenLabs realtime. */
const MAX_KEYTERMS = 50;
/** Max characters per keyterm. */
const MAX_KEYTERM_CHARS = 20;

// ---------------------------------------------------------------------------
// Base64 encoding (chunked to avoid stack overflow on large PCM buffers)
// ---------------------------------------------------------------------------

/**
 * Encode an ArrayBuffer to base64 using chunked encoding.
 *
 * `btoa(String.fromCharCode(...bytes))` blows the JS call stack when the
 * spread operator creates too many function arguments. Splitting into 32 KB
 * chunks avoids this without measurable perf overhead on typical PCM frames.
 */
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const CHUNK_SIZE = 0x8000; // 32 KB
  const parts: string[] = [];

  for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
    const chunk = bytes.subarray(i, i + CHUNK_SIZE);
    parts.push(String.fromCharCode(...chunk));
  }

  return btoa(parts.join(''));
}

// ---------------------------------------------------------------------------
// Connection URL builder
// ---------------------------------------------------------------------------

/**
 * Build the WebSocket URL with query parameters.
 *
 * ElevenLabs expects all session config in the URL query string:
 * model_id, language_code, keyterms, include_timestamps, commit_strategy.
 */
function buildConnectionURL(config: ASRSessionConfig): string {
  const params = new URLSearchParams();
  params.set('model_id', 'scribe_v2_realtime');

  // Language — ElevenLabs uses ISO 639-1, strip locale suffix from zh-CN/en-US
  if (config.language) {
    const lang = config.language.split('-')[0].toLowerCase();
    params.set('language_code', lang);
  }

  // Keyterms (hotwords) — capped at 50, each ≤ 20 chars, deduped
  const allHotwords = [
    ...(config.identityHotwords || []),
    ...(config.hotwords || []),
  ];
  if (allHotwords.length > 0) {
    const seen = new Set<string>();
    const keyterms: string[] = [];
    for (const w of allHotwords) {
      const kt = w.trim().substring(0, MAX_KEYTERM_CHARS);
      if (kt && !seen.has(kt)) {
        seen.add(kt);
        keyterms.push(kt);
        if (keyterms.length >= MAX_KEYTERMS) break;
      }
    }
    for (const kt of keyterms) {
      params.append('keyterms', kt);
    }
  }

  // Word-level timestamps — sent as committed_transcript_with_timestamps
  params.set('include_timestamps', 'true');

  // Use manual commit strategy — we signal end-of-speech via commit:true
  // rather than relying on server-side VAD.
  params.set('commit_strategy', 'manual');

  return `${ELEVENLABS_WSS}?${params.toString()}`;
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

export class ElevenLabsAdapter implements ASRProviderAdapter {
  readonly name = 'elevenlabs';
  /** ElevenLabs sends partial_transcript + committed_transcript. */
  readonly accumulatesResults = false;

  /** ElevenLabs sends session_started ack — not immediate-ready. */
  readonly immediateReady = false;

  private accumulatedText = '';
  /** True after sendFinish() was called (commit:true sent to ElevenLabs). */
  private finishSent = false;

  async createConnection(
    env: Record<string, any>,
    config?: ASRSessionConfig,
  ): Promise<WebSocket> {
    const apiKey = env.ELEVENLABS_API_KEY as string;
    if (!apiKey) throw new Error('ELEVENLABS_API_KEY not configured');

    // Build the URL with session config (model_id, language, keyterms, etc.)
    const url = config
      ? buildConnectionURL(config)
      : ELEVENLABS_WSS;

    // CF Workers: standard WebSocket constructor can't pass custom headers.
    // Use fetch with Upgrade header (same pattern as AlibabaAdapter).
    const resp = await fetch(url, {
      headers: {
        Upgrade: 'websocket',
        'xi-api-key': apiKey,
      },
    });

    const ws = resp.webSocket;
    if (!ws) {
      let errorBody = '';
      try { errorBody = await resp.text(); } catch {}
      throw new Error(
        `ElevenLabs WebSocket upgrade failed: ${resp.status} ${resp.statusText}${errorBody ? ' — ' + errorBody : ''}`,
      );
    }

    ws.accept();
    return ws;
  }

  sendInit(_ws: WebSocket, _config: ASRSessionConfig): void {
    // ElevenLabs config is all in the URL query params (set during
    // createConnection). The server sends session_started after connection,
    // then the client can immediately send audio.
    this.accumulatedText = '';
    this.finishSent = false;
  }

  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void {
    if (ws.readyState !== WebSocket.OPEN) return;

    // ElevenLabs expects base64-encoded PCM in JSON:
    // { "message_type":"input_audio_chunk", "audio_base_64":"...", "commit":false }
    const base64 = arrayBufferToBase64(pcm);

    ws.send(
      JSON.stringify({
        message_type: 'input_audio_chunk',
        audio_base_64: base64,
        sample_rate: 16000,
        commit: false,
      }),
    );
  }

  sendFinish(ws: WebSocket): void {
    if (ws.readyState !== WebSocket.OPEN) return;

    this.finishSent = true;

    // Send empty audio chunk with commit:true to force final transcription.
    // ElevenLabs will flush remaining audio, return final committed_transcript,
    // then close the WebSocket.
    ws.send(
      JSON.stringify({
        message_type: 'input_audio_chunk',
        audio_base_64: '',
        commit: true,
      }),
    );
  }

  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null {
    if (typeof data !== 'string') return null;

    let msg: any;
    try {
      msg = JSON.parse(data);
    } catch {
      return null;
    }

    const messageType = msg.message_type as string | undefined;
    if (!messageType) return null;

    // --- Error events (all 13 types defined in ElevenLabs API) ---
    // These must be handled BEFORE success cases so errors don't fall through to default.
    // Session-time-limit is the most common failure mode for long dictation sessions.

    if (messageType.startsWith('scribe')) {
      // Map ElevenLabs error types to readable messages.
      // Reference: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
      const errorLabels: Record<string, string> = {
        scribeError: 'ElevenLabs 转录错误',
        scribeAuthError: 'ElevenLabs API 密钥无效',
        scribeQuotaExceededError: 'ElevenLabs 额度用尽',
        scribeThrottledError: 'ElevenLabs 请求过于频繁',
        scribeUnacceptedTermsError: 'ElevenLabs 未接受服务条款',
        scribeRateLimitedError: 'ElevenLabs 速率限制',
        scribeQueueOverflowError: 'ElevenLabs 队列溢出',
        scribeResourceExhaustedError: 'ElevenLabs 资源耗尽',
        scribeSessionTimeLimitExceededError: '单次转录时长超限（请分段录音）',
        scribeInputError: 'ElevenLabs 输入错误',
        scribeChunkSizeExceededError: 'ElevenLabs 音频块过大',
        scribeInsufficientAudioActivityError: 'ElevenLabs 音频活动不足',
        scribeTranscriberError: 'ElevenLabs 转录引擎错误',
      };
      const label = errorLabels[messageType] || `ElevenLabs: ${messageType}`;
      const detail = (msg.error || msg.message || msg.detail || '') as string;
      const errorMessage = detail ? `${label} — ${detail}` : label;

      console.error(`[ElevenLabs] ${messageType}: ${errorMessage}`);

      return {
        type: 'error',
        is_last_package: true,
        error: errorMessage,
        provider: this.name,
      };
    }

    switch (messageType) {
      case 'session_started':
        return { type: 'started', provider: this.name };

      case 'partial_transcript': {
        // Interim result — may still change. Show as live preview.
        const text = (msg.text as string) || '';
        return {
          type: 'result',
          code: 20000000,
          is_last_package: false,
          result: {
            text,
            utterances: [{ text, definite: false }],
          },
          provider: this.name,
        };
      }

      case 'committed_transcript': {
        // Final committed segment — will not change.
        const text = (msg.text as string) || '';

        // After commit:true was sent, the response to it is the FINAL result.
        // Signal as "finished" so the proxy knows the session is complete and
        // won't refund quota on upstream close.
        // IMPORTANT: emit finished even when text is empty — otherwise the proxy
        // never receives a final event, waitForFinal() times out, and the client
        // falls through to the retranscribe chain wasting 2+ upstream API calls.
        if (this.finishSent) {
          return {
            type: 'finished',
            code: 20000000,
            is_last_package: true,
            result: {
              text: text ? text : this.accumulatedText,
              utterances: [{ text: text || '', definite: true }],
            },
            provider: this.name,
          };
        }

        if (!text) return null;

        this.accumulatedText += text;

        return {
          type: 'result',
          code: 20000000,
          is_last_package: false,
          result: {
            text: this.accumulatedText,
            utterances: [{ text, definite: true }],
          },
          provider: this.name,
        };
      }

      case 'committed_transcript_with_timestamps':
        // Already handled by committed_transcript above. Skip duplicate.
        return null;

      case 'committed_transcript_entities':
        // Entity detection output — informational, not transcription.
        return null;

      default:
        return null;
    }
  }

  isReady(event: NormalizedASREvent): boolean {
    return event.type === 'started';
  }

  isFinished(event: NormalizedASREvent): boolean {
    return event.type === 'finished' || event.type === 'error';
  }

  // -------------------------------------------------------------------------
  // Async file transcription (retranscribe fallback chain)
  // -------------------------------------------------------------------------

  async transcribeFile(
    env: Record<string, any>,
    audioData: ArrayBuffer,
    config: ASRSessionConfig,
  ): Promise<string> {
    const apiKey = env.ELEVENLABS_API_KEY as string;
    if (!apiKey) throw new Error('ELEVENLABS_API_KEY not configured');

    const formData = new FormData();
    formData.append(
      'file',
      new Blob([audioData], { type: 'audio/wav' }),
      'recording.wav',
    );
    formData.append('model_id', 'scribe_v2');

    // Language — ISO 639-1 two-letter code
    if (config.language) {
      const lang = config.language.split('-')[0].toLowerCase();
      formData.append('language_code', lang);
    }

    console.log(
      `[ElevenLabs File] Submitting ${audioData.byteLength} bytes, lang=${config.language || 'auto'}`,
    );

    const resp = await fetch(ELEVENLABS_FILE_API, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey },
      body: formData,
    });

    if (!resp.ok) {
      let errorBody = '';
      try { errorBody = await resp.text(); } catch {}
      throw new Error(
        `ElevenLabs file transcription failed: ${resp.status} ${resp.statusText}${errorBody ? ' — ' + errorBody : ''}`,
      );
    }

    const result = (await resp.json()) as { text: string };
    const text = result.text || '';

    console.log(
      `[ElevenLabs File] Transcription done (${text.length} chars)`,
    );
    return text;
  }
}
