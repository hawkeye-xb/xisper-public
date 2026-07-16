/**
 * Soniox Real-Time ASR Adapter
 *
 * Protocol: WebSocket with JSON config frame + raw PCM binary frames.
 * Endpoint: wss://stt-rt.soniox.com/transcribe-websocket
 * Model: stt-rt-v4 (latest, 60+ languages)
 *
 * Message flow:
 *   1. Connect → send JSON config { api_key, model, audio_format, ... }
 *   2. Send binary PCM frames (pcm_s16le)
 *   3. Send empty string "" → graceful close
 *   4. Receive JSON: { tokens: [{ text, is_final, confidence, ... }], finished? }
 *
 * Docs: https://soniox.com/docs/stt/api-reference/websocket-api
 */

import type {
  ASRProviderAdapter,
  ASRSessionConfig,
  NormalizedASREvent,
  NormalizedUtterance,
} from './types';

const SONIOX_WS_URL = 'https://stt-rt.soniox.com/transcribe-websocket';

export class SonioxAdapter implements ASRProviderAdapter {
  readonly name = 'soniox';

  /**
   * Soniox sends incremental token arrays per message.
   * Each message contains new tokens since the last response.
   * We treat it as non-accumulating so the proxy handles accumulation.
   */
  readonly accumulatesResults = false;

  /**
   * Soniox handles VAD internally with endpoint detection.
   * No need for artificial delay before finish.
   */
  readonly minAudioFlowBeforeFinishMs = undefined;

  /**
   * Soniox does not send a handshake ack after config — it's ready immediately.
   * The proxy should skip waiting for an isReady message.
   */
  readonly immediateReady = true;

  private apiKey: string = '';

  async createConnection(env: Record<string, any>): Promise<WebSocket> {
    const apiKey = env.SONIOX_API_KEY as string;
    if (!apiKey) throw new Error('SONIOX_API_KEY not configured');
    this.apiKey = apiKey;

    // Cloudflare Workers: use fetch with Upgrade header for WebSocket handshake.
    const resp = await fetch(SONIOX_WS_URL, {
      headers: {
        Upgrade: 'websocket',
      },
    });

    const ws = resp.webSocket;
    if (!ws) {
      throw new Error(`Soniox WebSocket upgrade failed: ${resp.status} ${resp.statusText}`);
    }

    ws.accept();
    return ws;
  }

  sendInit(ws: WebSocket, config: ASRSessionConfig): void {
    // Map our format names to Soniox audio_format values.
    // Soniox uses "pcm_s16le" for raw PCM, "auto" for container formats.
    let audioFormat = 'pcm_s16le';
    if (config.format === 'opus' || config.format === 'wav' || config.format === 'flac') {
      audioFormat = 'auto';
    }

    // Build language hints from config.language (e.g. "zh-CN" → ["zh"], "en-US" → ["en"])
    const langHints: string[] = [];
    if (config.language) {
      const lang = config.language.split('-')[0].toLowerCase();
      if (lang) langHints.push(lang);
    }

    const initMsg: Record<string, any> = {
      api_key: this.apiKey,
      model: 'stt-rt-v4',
      audio_format: audioFormat,
      sample_rate: config.sampleRate || 16000,
      num_channels: 1,
      enable_endpoint_detection: true,
      max_endpoint_delay_ms: 1500,
    };

    if (langHints.length > 0) {
      initMsg.language_hints = langHints;
    }

    // Context biasing — map hotwords to Soniox context.terms
    const terms: string[] = [];
    if (config.hotwords && config.hotwords.length > 0) {
      terms.push(...config.hotwords);
    }
    if (terms.length > 0) {
      initMsg.context = { terms };
    }

    ws.send(JSON.stringify(initMsg));
  }

  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void {
    // Soniox accepts raw binary PCM frames directly — no wrapping needed.
    ws.send(pcm);
  }

  sendFinish(ws: WebSocket): void {
    // Soniox protocol: send an empty string to signal end of audio.
    console.log(`[Soniox] sendFinish() invoked at ${Date.now()}, readyState=${ws.readyState}`);
    ws.send('');
  }

  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null {
    if (typeof data !== 'string') return null;

    // Diagnostic: raw message preview — needed to verify Soniox protocol observation
    // (e.g. whether `finished:true` is actually sent before close, or replaced by `error_code`).
    // Truncated to 800 chars; remove once Soniox close-without-finished root cause is confirmed.
    console.log(`[Soniox] raw msg (len=${data.length}): ${data.substring(0, 800)}`);

    let msg: any;
    try {
      msg = JSON.parse(data);
    } catch {
      console.warn('[Soniox] Non-JSON text frame:', data.substring(0, 200));
      return null;
    }

    // Error response
    if (msg.error_code || msg.error_message) {
      return {
        type: 'error',
        error: msg.error_message || `Soniox error code: ${msg.error_code}`,
        provider: this.name,
      };
    }

    // Finished response: { tokens: [], finished: true }
    if (msg.finished === true) {
      return {
        type: 'finished',
        code: 20000000,
        is_last_package: true,
        provider: this.name,
      };
    }

    // Token response: { tokens: [...], final_audio_proc_ms, total_audio_proc_ms }
    const tokens = msg.tokens;
    if (!Array.isArray(tokens) || tokens.length === 0) {
      return null;
    }

    // Build utterances from tokens.
    // Soniox tokens have: { text, start_ms, end_ms, confidence, is_final, speaker }
    // Group consecutive tokens by is_final status into utterances.
    const utterances: NormalizedUtterance[] = [];
    let currentText = '';
    let currentIsFinal = tokens[0]?.is_final ?? false;
    let currentStartMs: number | undefined;
    let currentEndMs: number | undefined;

    for (const token of tokens) {
      const tokenIsFinal = token.is_final ?? false;

      if (tokenIsFinal !== currentIsFinal && currentText) {
        // Flush current group
        utterances.push({
          text: currentText,
          start_time: currentStartMs != null ? currentStartMs / 1000 : undefined,
          end_time: currentEndMs != null ? currentEndMs / 1000 : undefined,
          definite: currentIsFinal,
        });
        currentText = '';
        currentStartMs = undefined;
        currentEndMs = undefined;
        currentIsFinal = tokenIsFinal;
      }

      // Soniox appends "<end>" as a special end-of-stream token — strip it.
      const text = token.text === '<end>' ? '' : token.text;
      currentText += text;
      if (currentStartMs == null && token.start_ms != null) {
        currentStartMs = token.start_ms;
      }
      if (token.end_ms != null) {
        currentEndMs = token.end_ms;
      }
    }

    // Flush remaining
    if (currentText) {
      utterances.push({
        text: currentText,
        start_time: currentStartMs != null ? currentStartMs / 1000 : undefined,
        end_time: currentEndMs != null ? currentEndMs / 1000 : undefined,
        definite: currentIsFinal,
      });
    }

    const fullText = utterances.map(u => u.text).join('');

    return {
      type: 'result',
      code: 20000000,
      is_last_package: false,
      result: {
        text: fullText,
        utterances,
      },
      provider: this.name,
    };
  }

  isReady(_event: NormalizedASREvent): boolean {
    // Not called when immediateReady=true, but required by interface.
    return false;
  }

  isFinished(event: NormalizedASREvent): boolean {
    return event.type === 'finished' || event.type === 'error';
  }

  // ---------------------------------------------------------------------------
  // Async file transcription — Soniox REST API (stt-async-v4)
  //
  // The real-time WebSocket requires audio at real-time pace; burst-sending
  // pre-recorded audio causes disconnection. For retranscribe / retry,
  // we use the Async REST API which processes faster than real-time.
  //
  // Flow: upload WAV → create transcription → poll → get transcript → cleanup
  // ---------------------------------------------------------------------------

  private static readonly SONIOX_API = 'https://api.soniox.com';
  private static readonly ASYNC_MODEL = 'stt-async-v4';
  private static readonly POLL_INTERVAL_MS = 1000;
  private static readonly MAX_POLL_ATTEMPTS = 120; // 120s max wait

  async transcribeFile(env: Record<string, any>, audioData: ArrayBuffer, config: ASRSessionConfig): Promise<string> {
    const apiKey = env.SONIOX_API_KEY as string;
    if (!apiKey) throw new Error('SONIOX_API_KEY not configured');

    const authHeader = { Authorization: `Bearer ${apiKey}` };

    // 1. Upload WAV file
    const formData = new FormData();
    formData.append('file', new Blob([audioData], { type: 'audio/wav' }), 'recording.wav');

    const uploadResp = await fetch(`${SonioxAdapter.SONIOX_API}/v1/files`, {
      method: 'POST',
      headers: authHeader,
      body: formData,
    });
    if (!uploadResp.ok) {
      const errText = await uploadResp.text();
      throw new Error(`Soniox file upload failed: ${uploadResp.status} ${errText}`);
    }
    const uploadResult = await uploadResp.json() as { id: string };
    const fileId = uploadResult.id;
    console.log(`[Soniox Async] File uploaded: ${fileId}, size=${audioData.byteLength}`);

    // 2. Create transcription job
    const langHints: string[] = [];
    if (config.language) {
      const lang = config.language.split('-')[0].toLowerCase();
      if (lang) langHints.push(lang);
    }

    const createBody: Record<string, any> = {
      model: SonioxAdapter.ASYNC_MODEL,
      file_id: fileId,
    };
    if (langHints.length > 0) createBody.language_hints = langHints;

    // Context biasing
    const terms: string[] = [];
    if (config.hotwords && config.hotwords.length > 0) terms.push(...config.hotwords);
    if (terms.length > 0) createBody.context = { terms };

    const createResp = await fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions`, {
      method: 'POST',
      headers: { ...authHeader, 'Content-Type': 'application/json' },
      body: JSON.stringify(createBody),
    });
    if (!createResp.ok) {
      const errText = await createResp.text();
      // Cleanup uploaded file
      await fetch(`${SonioxAdapter.SONIOX_API}/v1/files/${fileId}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
      throw new Error(`Soniox transcription create failed: ${createResp.status} ${errText}`);
    }
    const job = await createResp.json() as { id: string; status: string };
    console.log(`[Soniox Async] Job created: ${job.id}, status=${job.status}`);

    // 3. Poll for completion
    let status = job.status;
    let attempts = 0;
    while (status !== 'completed' && status !== 'error' && attempts < SonioxAdapter.MAX_POLL_ATTEMPTS) {
      await new Promise((r) => setTimeout(r, SonioxAdapter.POLL_INTERVAL_MS));
      attempts++;

      const pollResp = await fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions/${job.id}`, {
        headers: authHeader,
      });
      if (!pollResp.ok) {
        console.warn(`[Soniox Async] Poll failed: ${pollResp.status}`);
        continue;
      }
      const pollResult = await pollResp.json() as { status: string; error_message?: string };
      status = pollResult.status;

      if (status === 'error') {
        // Cleanup
        await fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions/${job.id}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
        await fetch(`${SonioxAdapter.SONIOX_API}/v1/files/${fileId}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
        throw new Error(`Soniox transcription failed: ${pollResult.error_message || 'unknown error'}`);
      }
    }

    if (status !== 'completed') {
      // Cleanup on timeout
      await fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions/${job.id}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
      await fetch(`${SonioxAdapter.SONIOX_API}/v1/files/${fileId}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
      throw new Error(`Soniox transcription timed out after ${attempts}s`);
    }

    console.log(`[Soniox Async] Job completed after ${attempts}s`);

    // 4. Get transcript
    const transcriptResp = await fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions/${job.id}/transcript`, {
      headers: authHeader,
    });
    if (!transcriptResp.ok) {
      const errText = await transcriptResp.text();
      throw new Error(`Soniox transcript fetch failed: ${transcriptResp.status} ${errText}`);
    }
    const transcript = await transcriptResp.json() as { text: string };

    // 5. Cleanup (fire-and-forget)
    fetch(`${SonioxAdapter.SONIOX_API}/v1/transcriptions/${job.id}`, { method: 'DELETE', headers: authHeader }).catch(() => {});
    fetch(`${SonioxAdapter.SONIOX_API}/v1/files/${fileId}`, { method: 'DELETE', headers: authHeader }).catch(() => {});

    console.log(`[Soniox Async] Transcript received (${transcript.text?.length ?? 0} chars)`);
    return transcript.text || '';
  }
}
