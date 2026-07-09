/**
 * Qwen3-ASR-Flash Realtime Adapter
 *
 * Protocol: OpenAI Realtime-compatible WebSocket (JSON text frames only).
 * Audio is sent as base64-encoded PCM inside JSON, NOT binary frames.
 * Supports context biasing via `corpus.text` in session.update.
 *
 * Known issue: QwenLM/Qwen3-ASR#106 — corpus_text leaks into output.
 * corpus_text is DISABLED for this adapter. Tested with instructional framing
 * + capped word lists — model still hallucinates. Hotword biasing relies on
 * LLM postprocess instead. Client still sends hotwords/identityHotwords
 * uniformly; this adapter simply ignores them.
 *
 * Docs: https://help.aliyun.com/zh/model-studio/qwen-real-time-speech-recognition
 */

import type {
  ASRProviderAdapter,
  ASRSessionConfig,
  NormalizedASREvent,
} from './types';

const DASHSCOPE_REALTIME = 'https://dashscope.aliyuncs.com/api-ws/v1/realtime';

let eventIdCounter = 0;

function nextEventId(): string {
  return `evt_${Date.now().toString(36)}_${++eventIdCounter}`;
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

// Qwen3-ASR corpus_text is DISABLED.
// QwenLM/Qwen3-ASR#106: model hallucinates corpus_text into transcription output,
// even with small word lists + instructional framing. Tested with 50 words, still
// produces 600+ chars of garbage. Feature is fundamentally broken in the model.
// Hotwords/corrections are handled by LLM postprocess instead.

export class Qwen3ASRAdapter implements ASRProviderAdapter {
  readonly name = 'qwen3-asr';
  /**
   * Qwen3 realtime sends per-turn completed transcriptions.
   * With server VAD each speech segment produces a completed event.
   * We treat it as non-accumulating so the proxy accumulates across turns.
   */
  readonly accumulatesResults = false;

  /**
   * Qwen3 server VAD (silence_duration_ms=400) only auto-commits audio after
   * detecting 400ms of silence. When buffered audio is flushed as a burst,
   * the VAD has no real-time silence gap to trigger on. We send an explicit
   * input_audio_buffer.commit in sendFinish, but the server still needs time
   * to process the committed audio before session.finish terminates it.
   * 800ms gives headroom for commit processing + transcription.
   */
  readonly minAudioFlowBeforeFinishMs = 800;

  /**
   * Qwen3 Realtime wraps audio as base64 JSON text frames, inflating ~4/3×.
   * Dashscope enforces a 262144-byte (256 KB) max WebSocket frame size.
   * 180 000 bytes raw PCM → ~240 KB base64+JSON → safely under the limit.
   */
  private readonly maxAudioFrameBytes = 180_000;

  private model: string;

  constructor(model?: string) {
    this.model = model || 'qwen3-asr-flash-realtime';
  }

  async createConnection(env: Record<string, any>): Promise<WebSocket> {
    const apiKey = env.ALIBABA_API_KEY as string;
    if (!apiKey) throw new Error('ALIBABA_API_KEY not configured');

    // Cloudflare Workers: use fetch with Upgrade header for WebSocket handshake.
    const url = `${DASHSCOPE_REALTIME}?model=${encodeURIComponent(this.model)}`;
    const resp = await fetch(url, {
      headers: {
        Upgrade: 'websocket',
        Authorization: `Bearer ${apiKey}`,
        'OpenAI-Beta': 'realtime=v1',
      },
    });

    const ws = resp.webSocket;
    if (!ws) {
      throw new Error(`Qwen3 ASR WebSocket upgrade failed: ${resp.status} ${resp.statusText}`);
    }

    ws.accept();
    return ws;
  }

  sendInit(ws: WebSocket, config: ASRSessionConfig): void {
    const lang = config.language ? config.language.split('-')[0].toLowerCase() : 'zh';

    const sessionUpdate: Record<string, any> = {
      event_id: nextEventId(),
      type: 'session.update',
      session: {
        modalities: ['text'],
        input_audio_format: config.format === 'opus' ? 'opus' : 'pcm',
        sample_rate: config.sampleRate || 16000,
        input_audio_transcription: {
          language: lang,
          // corpus_text DISABLED — see comment above
        },
        turn_detection: {
          type: 'server_vad',
          threshold: 0.0,
          silence_duration_ms: 400,
        },
      },
    };

    ws.send(JSON.stringify(sessionUpdate));
  }

  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void {
    // Qwen3 realtime expects base64-encoded audio in a JSON text frame.
    // Dashscope enforces 256 KB max frame — split large buffers at the
    // raw PCM level before base64 inflation (~4/3×).
    if (pcm.byteLength > this.maxAudioFrameBytes) {
      for (let offset = 0; offset < pcm.byteLength; offset += this.maxAudioFrameBytes) {
        const chunk = pcm.slice(offset, Math.min(offset + this.maxAudioFrameBytes, pcm.byteLength));
        ws.send(JSON.stringify({
          event_id: nextEventId(),
          type: 'input_audio_buffer.append',
          audio: arrayBufferToBase64(chunk),
        }));
      }
    } else {
      ws.send(JSON.stringify({
        event_id: nextEventId(),
        type: 'input_audio_buffer.append',
        audio: arrayBufferToBase64(pcm),
      }));
    }
  }

  sendFinish(ws: WebSocket): void {
    // Force-commit any audio still in the buffer. With server VAD, audio is
    // only auto-committed after silence_duration_ms of silence. If the user
    // stops recording before that silence window, the buffer stays uncommitted
    // and session.finish would discard it. Explicit commit ensures all audio
    // is processed before the session ends.
    ws.send(JSON.stringify({
      event_id: nextEventId(),
      type: 'input_audio_buffer.commit',
    }));
    ws.send(JSON.stringify({
      event_id: nextEventId(),
      type: 'session.finish',
    }));
  }

  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null {
    if (typeof data !== 'string') {
      // Qwen3 realtime only sends text frames
      return null;
    }

    let msg: any;
    try {
      msg = JSON.parse(data);
    } catch {
      return null;
    }

    const type = msg?.type as string | undefined;
    if (!type) return null;

    switch (type) {
      // Session lifecycle
      case 'session.created':
        // Connection established but not yet configured
        return null;

      case 'session.updated':
        // Configuration acknowledged — ready to receive audio
        return { type: 'started', provider: this.name };

      // Transcription results
      case 'conversation.item.input_audio_transcription.text': {
        // Interim/streaming partial result
        const text = msg.stash || msg.transcript || '';
        if (!text) return null;

        return {
          type: 'result',
          code: 20000000,
          is_last_package: false,
          result: {
            text,
            utterances: [{
              text,
              definite: false,
            }],
          },
          provider: this.name,
        };
      }

      case 'conversation.item.input_audio_transcription.completed': {
        // Final transcription for one speech segment
        const text = msg.transcript || '';
        if (!text) return null;

        return {
          type: 'result',
          code: 20000000,
          is_last_package: false,
          result: {
            text,
            utterances: [{
              text,
              definite: true,
            }],
          },
          provider: this.name,
        };
      }

      // VAD events (informational — forward as result with no text change)
      case 'input_audio_buffer.speech_started':
      case 'input_audio_buffer.speech_stopped':
      case 'input_audio_buffer.committed':
        return null;

      // Session end
      case 'session.finished':
        return {
          type: 'finished',
          code: 20000000,
          is_last_package: true,
          result: msg.transcript ? { text: msg.transcript } : undefined,
          provider: this.name,
        };

      // Error
      case 'error':
        return {
          type: 'error',
          error: msg.error?.message || msg.message || 'Unknown Qwen3 ASR error',
          provider: this.name,
        };

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
}
