/**
 * Alibaba Fun-ASR (DashScope) ASR Adapter
 *
 * Protocol: standard WebSocket with JSON text frames + raw PCM binary frames.
 * Docs: https://help.aliyun.com/zh/model-studio/fun-asr-real-time-speech-recognition-api-reference/
 */

import type {
  ASRProviderAdapter,
  ASRSessionConfig,
  NormalizedASREvent,
  NormalizedUtterance,
} from './types';

const DASHSCOPE_HTTPS = 'https://dashscope.aliyuncs.com/api-ws/v1/inference/';

let taskIdCounter = 0;

function generateTaskId(): string {
  taskIdCounter++;
  const ts = Date.now().toString(36);
  const rnd = Math.random().toString(36).slice(2, 10);
  return `${ts}${rnd}${taskIdCounter}`.slice(0, 32);
}

export class AlibabaAdapter implements ASRProviderAdapter {
  readonly name = 'alibaba';
  readonly accumulatesResults = false;

  private taskId = '';

  async createConnection(env: Record<string, any>): Promise<WebSocket> {
    const apiKey = env.ALIBABA_API_KEY as string;
    if (!apiKey) throw new Error('ALIBABA_API_KEY not configured');

    // Cloudflare Workers: standard WebSocket constructor cannot pass custom headers.
    // Use fetch with Upgrade header to perform the WebSocket handshake with auth.
    const resp = await fetch(DASHSCOPE_HTTPS, {
      headers: {
        Upgrade: 'websocket',
        Authorization: `Bearer ${apiKey}`,
      },
    });

    const ws = resp.webSocket;
    if (!ws) {
      throw new Error(`DashScope WebSocket upgrade failed: ${resp.status} ${resp.statusText}`);
    }

    ws.accept();
    return ws;
  }

  sendInit(ws: WebSocket, config: ASRSessionConfig): void {
    this.taskId = generateTaskId();

    const parameters: Record<string, any> = {
      format: config.format || 'pcm',
      sample_rate: config.sampleRate || 16000,
      language_hints: config.language ? [config.language.replace('-', '_')] : undefined,
    };

    if (config.enablePunctuation !== undefined) {
      parameters.punctuation_prediction_enabled = config.enablePunctuation;
    }
    if (config.enableITN !== undefined) {
      parameters.inverse_text_normalization_enabled = config.enableITN;
    }
    if (config.enableSmoothing) {
      parameters.disfluency_removal_enabled = true;
    }
    if (config.semanticPunctuationEnabled !== undefined) {
      parameters.semantic_punctuation_enabled = config.semanticPunctuationEnabled;
    }
    if (config.maxSentenceSilence !== undefined) {
      parameters.max_sentence_silence = config.maxSentenceSilence;
    }
    if (config.multiThresholdModeEnabled !== undefined) {
      parameters.multi_threshold_mode_enabled = config.multiThresholdModeEnabled;
    }

    const payload: Record<string, any> = {
      task_group: 'audio',
      task: 'asr',
      function: 'recognition',
      model: 'fun-asr-flash-8k-realtime',
      parameters,
      input: {},
    };

    // Optional hotword vocabulary
    const vocabId = config.vocabularyId;
    if (vocabId) {
      parameters.vocabulary_id = vocabId;
    }

    const msg = {
      header: {
        action: 'run-task',
        task_id: this.taskId,
        streaming: 'duplex',
      },
      payload,
    };

    ws.send(JSON.stringify(msg));
  }

  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void {
    // Alibaba accepts raw PCM binary frames — zero wrapping needed
    ws.send(pcm);
  }

  sendFinish(ws: WebSocket): void {
    const msg = {
      header: {
        action: 'finish-task',
        task_id: this.taskId,
        streaming: 'duplex',
      },
      payload: { input: {} },
    };
    ws.send(JSON.stringify(msg));
  }

  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null {
    if (typeof data !== 'string') {
      // Alibaba should only return text frames; ignore unexpected binary
      return null;
    }

    let msg: any;
    try {
      msg = JSON.parse(data);
    } catch {
      return null;
    }

    const event = msg?.header?.event as string | undefined;
    if (!event) return null;

    switch (event) {
      case 'task-started':
        return { type: 'started', provider: this.name };

      case 'result-generated': {
        const sentence = msg.payload?.output?.sentence;
        if (!sentence) return null;

        // Skip heartbeat-only frames
        if (sentence.heartbeat === true && !sentence.text) return null;

        const utterance: NormalizedUtterance = {
          text: sentence.text || '',
          start_time: sentence.begin_time,
          end_time: sentence.end_time ?? null,
          // Fun-ASR returns sentence_end as number (1/0) or boolean (true/false)
          definite: sentence.sentence_end === true || sentence.sentence_end === 1 || sentence.sentence_end === '1',
        };

        // Build full accumulated text from definite utterances over time.
        // Each result-generated only contains the *current* sentence being
        // recognised, so we surface it directly.
        return {
          type: 'result',
          code: 20000000,
          is_last_package: false,
          result: {
            text: sentence.text || '',
            utterances: [utterance],
          },
          provider: this.name,
        };
      }

      case 'task-finished':
        return {
          type: 'finished',
          code: 20000000,
          is_last_package: true,
          provider: this.name,
        };

      case 'task-failed':
        return {
          type: 'error',
          error: msg.header?.error_message || 'Unknown Alibaba ASR error',
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
