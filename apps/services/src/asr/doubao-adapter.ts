/**
 * Doubao (Volcengine BigASR) Adapter
 *
 * Protocol: proprietary binary framing over WebSocket.
 * Auth via URL query parameters. Binary header (4 bytes) + payload size (4 bytes) + payload.
 */

import type {
  ASRProviderAdapter,
  ASRSessionConfig,
  NormalizedASREvent,
  NormalizedUtterance,
} from './types';

// ---------------------------------------------------------------------------
// Binary protocol constants
// ---------------------------------------------------------------------------

const Version = 0b0001;
const HeaderSizeUnits = 0b0001; // 1 unit = 4 bytes

const MsgType = {
  FullClientRequest: 0b0001,
  AudioOnlyRequest: 0b0010,
  FullServerResponse: 0b1001,
  ServerAck: 0b1011,
  ServerError: 0b1111,
} as const;

const MsgFlags = {
  None: 0b0000,
  WithSequence: 0b0001,
  LastPackage: 0b0010,
} as const;

const Serialization = { None: 0b0000, JSON: 0b0001 } as const;
const Compression = { None: 0b0000, Gzip: 0b0001 } as const;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function buildHeader(
  msgType: number,
  msgFlags: number,
  serialization: number,
  compression: number,
): Uint8Array {
  const h = new Uint8Array(4);
  h[0] = (Version << 4) | HeaderSizeUnits;
  h[1] = (msgType << 4) | msgFlags;
  h[2] = (serialization << 4) | compression;
  h[3] = 0;
  return h;
}

function encodePayloadSize(size: number): Uint8Array {
  const buf = new Uint8Array(4);
  buf[0] = (size >> 24) & 0xff;
  buf[1] = (size >> 16) & 0xff;
  buf[2] = (size >> 8) & 0xff;
  buf[3] = size & 0xff;
  return buf;
}

function packFrame(header: Uint8Array, payload: Uint8Array): ArrayBuffer {
  const sizeBytes = encodePayloadSize(payload.length);
  const msg = new Uint8Array(4 + 4 + payload.length);
  msg.set(header, 0);
  msg.set(sizeBytes, 4);
  msg.set(payload, 8);
  return msg.buffer;
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

export class DoubaoAdapter implements ASRProviderAdapter {
  readonly name = 'doubao';
  readonly accumulatesResults = true;

  createConnection(env: Record<string, any>): WebSocket {
    const appId = env.DOUBAO_APP_ID as string;
    const accessToken = env.DOUBAO_ACCESS_TOKEN as string;
    if (!appId || !accessToken) throw new Error('Doubao credentials not configured');

    const baseURL = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';
    const url = new URL(baseURL);
    url.searchParams.append('api_app_key', appId);
    url.searchParams.append('api_access_key', accessToken);
    url.searchParams.append(
      'api_resource_id',
      (env.DOUBAO_RESOURCE_ID as string) || 'volc.bigasr.sauc.duration',
    );
    if (env.DOUBAO_CLUSTER) {
      url.searchParams.append('cluster', env.DOUBAO_CLUSTER as string);
    }

    return new WebSocket(url.toString());
  }

  sendInit(ws: WebSocket, config: ASRSessionConfig): void {
    const requestPayload = {
      app: {
        appid: '', // filled by URL auth
        token: '',
        cluster: '',
      },
      user: { uid: 'proxy_user' },
      audio: {
        format: config.format || 'pcm',
        codec: 'raw',
        rate: config.sampleRate || 16000,
        bits: 16,
        channel: 1,
      },
      request: {
        model_name: 'bigmodel',
        reqid: `req_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`,
        nbest: 1,
        show_utterances: true,
        result_type: 'full',
        enable_itn: config.enableITN,
        enable_punc: config.enablePunctuation,
        enable_ddc: config.enableSmoothing,
        language: config.language || 'zh-CN',
      },
    };

    const payload = new TextEncoder().encode(JSON.stringify(requestPayload));
    const header = buildHeader(
      MsgType.FullClientRequest,
      MsgFlags.None,
      Serialization.JSON,
      Compression.None,
    );
    ws.send(packFrame(header, payload));
  }

  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void {
    const pcmBytes = new Uint8Array(pcm);
    const header = buildHeader(
      MsgType.AudioOnlyRequest,
      MsgFlags.None,
      Serialization.None,
      Compression.None,
    );
    ws.send(packFrame(header, pcmBytes));
  }

  sendFinish(ws: WebSocket): void {
    const header = buildHeader(
      MsgType.AudioOnlyRequest,
      MsgFlags.LastPackage,
      Serialization.None,
      Compression.None,
    );
    // Empty payload with LastPackage flag
    ws.send(packFrame(header, new Uint8Array(0)));
  }

  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null {
    if (typeof data === 'string') {
      // Doubao should only return binary frames
      return null;
    }

    const parsed = this.parseBinaryResponse(data);
    if (!parsed) return null;

    // Error from server
    if (parsed.error) {
      return {
        type: 'error',
        error: parsed.error,
        code: parsed.code,
        provider: this.name,
      };
    }

    const isLast = this.isLastPackage(parsed);
    const text = this.extractText(parsed);
    const utterances = this.extractUtterances(parsed);

    if (isLast) {
      return {
        type: 'finished',
        code: 20000000,
        is_last_package: true,
        result: text ? { text, utterances } : undefined,
        provider: this.name,
      };
    }

    if (text || (utterances && utterances.length > 0)) {
      return {
        type: 'result',
        code: 20000000,
        is_last_package: false,
        result: { text, utterances },
        provider: this.name,
      };
    }

    // Ack or unrecognised frame — ignore
    return null;
  }

  isReady(_event: NormalizedASREvent): boolean {
    // Doubao doesn't have an explicit "task-started" event;
    // the connection being open means it's ready to receive audio.
    // The proxy treats the successful open + sendInit as "ready".
    return true;
  }

  isFinished(event: NormalizedASREvent): boolean {
    return event.type === 'finished' || event.type === 'error';
  }

  // ---------------------------------------------------------------------------
  // Private binary protocol parsing (extracted from original asr-proxy.ts)
  // ---------------------------------------------------------------------------

  private isLastPackage(parsed: any): boolean {
    return !!(
      parsed &&
      (parsed.is_final === true ||
        parsed.is_last_package === true ||
        parsed.result?.is_final === true ||
        parsed.payload_msg?.is_final === true)
    );
  }

  private extractText(parsed: any): string {
    if (!parsed) return '';
    const text =
      parsed.text ||
      parsed.result?.text ||
      parsed.payload_msg?.result?.text ||
      parsed.payload_msg?.text ||
      '';
    return typeof text === 'string' ? text : '';
  }

  private extractUtterances(parsed: any): NormalizedUtterance[] | undefined {
    const raw =
      parsed.result?.utterances ||
      parsed.payload_msg?.result?.utterances;
    if (!Array.isArray(raw) || raw.length === 0) return undefined;

    return raw.map((u: any) => ({
      text: u.text || '',
      start_time: u.start_time,
      end_time: u.end_time ?? null,
      // Handle both boolean and number types for definite field
      definite: u.definite === true || u.definite === 1 || u.definite === '1',
    }));
  }

  private parseBinaryResponse(buffer: ArrayBuffer): any {
    try {
      const view = new DataView(buffer);
      const uint8View = new Uint8Array(buffer);

      if (buffer.byteLength < 8) return null;

      const headerByte = view.getUint8(0);
      const headerSizeUnits = (headerByte & 0x0f) || 1;
      const headerBytes = Math.max(4, headerSizeUnits * 4);

      const messageByte = view.getUint8(1);
      const messageType = (messageByte >> 4) & 0x0f;
      const messageFlags = messageByte & 0x0f;

      const serializationByte = view.getUint8(2);
      const serialization = (serializationByte >> 4) & 0x0f;
      const compression = serializationByte & 0x0f;

      let offset = headerBytes;

      // Server error
      if (messageType === MsgType.ServerError) {
        const errorCode = view.getUint32(offset, false);
        offset += 4;
        const errorSize = view.getUint32(offset, false);
        offset += 4;
        const errorMessage = new TextDecoder().decode(
          uint8View.slice(offset, offset + errorSize),
        );
        return { error: errorMessage, code: errorCode };
      }

      const isFullResponse = messageType === MsgType.FullServerResponse;
      const hasSequence =
        (messageFlags & MsgFlags.WithSequence) === MsgFlags.WithSequence;

      const tryParse = (start: number): any => {
        if (buffer.byteLength < start + 4) return null;
        const payloadSize = view.getUint32(start, false);
        const payloadOffset = start + 4;
        if (buffer.byteLength < payloadOffset + payloadSize) return null;

        const payload = uint8View.slice(payloadOffset, payloadOffset + payloadSize);

        if (compression === Compression.Gzip) {
          return { type: 'compressed', message: 'Gzip not implemented' };
        }

        if (serialization === Serialization.JSON) {
          const jsonStr = new TextDecoder().decode(payload);
          try {
            const parsed = JSON.parse(jsonStr);
            if ((messageFlags & MsgFlags.LastPackage) === MsgFlags.LastPackage) {
              parsed.is_last_package = true;
            }
            return { success: true, result: parsed };
          } catch {
            return null;
          }
        }

        return null;
      };

      if (isFullResponse && hasSequence) {
        offset += 4; // skip sequence number
      }

      const result = tryParse(offset);

      // Fallback: try without sequence skip
      if (result && !result.success && isFullResponse && hasSequence) {
        const fb = tryParse(headerBytes);
        if (fb?.success) return fb.result;
      }

      return result?.success ? result.result : null;
    } catch {
      return null;
    }
  }
}
