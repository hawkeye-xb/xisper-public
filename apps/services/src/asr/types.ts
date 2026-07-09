/**
 * ASR Provider Adapter — shared types
 *
 * Defines the contract between the proxy and any upstream ASR provider.
 * Adding a new provider only requires implementing `ASRProviderAdapter`.
 */

// ---------------------------------------------------------------------------
// Session config sent by the frontend (provider-agnostic)
// ---------------------------------------------------------------------------

export interface ASRSessionConfig {
  language: string // e.g. 'zh-CN', 'en-US'
  enableITN: boolean
  enablePunctuation: boolean
  enableSmoothing: boolean
  sampleRate: number // 16000
  format: string // 'pcm' | 'wav' | 'mp3' | 'opus' | 'speex' | 'aac' | 'amr'
  vocabularyId?: string
  /** User's own custom hotwords (small list, typically 5–20 items). */
  hotwords?: string[]
  /** Identity/system preset hotwords (large list, 200+). Adapter decides usage. */
  identityHotwords?: string[]
  /** Identity ID — server resolves hotwords from KV instead of client sending the full array. */
  identityId?: string
  /** Pre-generated recording ID from the client for end-to-end tracing. */
  recordingId?: string
  /** Semantic sentence boundary (higher accuracy); false = VAD-based, lower latency. Default true for accuracy. */
  semanticPunctuationEnabled?: boolean
  /** VAD silence threshold (ms), [200,6000]. Only when semanticPunctuationEnabled=false. Default 1300. */
  maxSentenceSilence?: number
  /** Limit VAD segment length. Only when semanticPunctuationEnabled=false. */
  multiThresholdModeEnabled?: boolean
  /** True when re-transcribing a saved recording (burst-send, not real-time). */
  retranscribe?: boolean
}

// ---------------------------------------------------------------------------
// Normalised ASR event — what the proxy sends to the frontend.
// Shape is intentionally compatible with the frontend `ASRResult` interface
// so `recognition.ts` needs zero changes.
// ---------------------------------------------------------------------------

export interface NormalizedUtterance {
  text: string
  start_time?: number
  end_time?: number | null
  definite: boolean
}

export interface NormalizedASREvent {
  type: 'started' | 'result' | 'finished' | 'error'
  code?: number
  is_last_package?: boolean
  result?: {
    text?: string
    utterances?: NormalizedUtterance[]
  }
  error?: string
  provider: string
}

// ---------------------------------------------------------------------------
// Provider adapter interface
// ---------------------------------------------------------------------------

export interface ASRProviderAdapter {
  /** Human-readable name for logging, e.g. "alibaba" | "doubao" */
  readonly name: string

  /**
   * If true, each `result` event already contains the full accumulated text
   * and all utterances (e.g. Doubao). The proxy forwards as-is.
   * If false, each `result` only carries the current segment (e.g. Alibaba).
   * The proxy accumulates definite utterances before forwarding.
   */
  readonly accumulatesResults: boolean

  /**
   * Minimum milliseconds audio should have been flowing to the upstream before
   * sending the finish signal. Only relevant for adapters whose server-side VAD
   * needs real-time-paced audio to detect speech boundaries (e.g. Qwen3 Realtime).
   * The proxy delays the finish if audio flow duration is shorter than this value.
   * Adapters that don't need this (e.g. Alibaba Fun-ASR) leave it undefined.
   */
  readonly minAudioFlowBeforeFinishMs?: number

  /**
   * If true, the provider is ready to receive audio immediately after sendInit —
   * it does not send a handshake acknowledgement message. The proxy will skip
   * waiting for an isReady event and start forwarding audio right away.
   * Default: false (proxy waits for an isReady message from the provider).
   */
  readonly immediateReady?: boolean

  /**
   * Create the upstream WebSocket connection.
   * May return an already-open WebSocket (e.g. Cloudflare fetch upgrade)
   * or a connecting one (standard constructor). The caller handles both.
   */
  createConnection(env: Record<string, any>): WebSocket | Promise<WebSocket>

  /**
   * Send the provider-specific initialisation message
   * (e.g. Alibaba run-task, Doubao full-client-request).
   * Called once after the upstream socket is open.
   */
  sendInit(ws: WebSocket, config: ASRSessionConfig): void

  /**
   * Send a raw PCM audio buffer to the upstream WebSocket.
   * The adapter wraps PCM into whatever framing the provider expects and
   * handles any provider-specific constraints (e.g. frame-size limits).
   *
   * Default adapters send one frame per call. Adapters with frame-size
   * constraints (e.g. Qwen3 base64 JSON with 256 KB limit) split internally.
   */
  sendAudio(ws: WebSocket, pcm: ArrayBuffer): void

  /**
   * Send the provider-specific "end of audio" signal.
   */
  sendFinish(ws: WebSocket): void

  /**
   * Parse a single upstream message into a NormalizedASREvent.
   * Return `null` for messages that should be silently ignored (e.g. heartbeats).
   */
  parseResponse(data: ArrayBuffer | string): NormalizedASREvent | null

  /** True when the provider signals "ready to receive audio". */
  isReady(event: NormalizedASREvent): boolean

  /** True when the provider signals "session complete". */
  isFinished(event: NormalizedASREvent): boolean

  /**
   * Optional: transcribe a complete audio file asynchronously.
   * Used for retranscribe / retry when the real-time WebSocket path is unsuitable
   * (e.g. Soniox requires real-time pacing; burst-sending pre-recorded audio fails).
   *
   * Adapters that support faster-than-real-time file transcription (e.g. Soniox
   * Async REST API) implement this. Adapters whose real-time WebSocket already
   * handles burst audio (e.g. Qwen3) can leave it undefined.
   *
   * Returns the final transcript text.
   */
  transcribeFile?(env: Record<string, any>, audioData: ArrayBuffer, config: ASRSessionConfig): Promise<string>
}
