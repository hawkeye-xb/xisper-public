/**
 * ASRClient
 *
 * Per-session URLSessionWebSocketTask client for the Xisper ASR proxy.
 *
 * Protocol (mirrors ws-manager.ts):
 *   Client → Proxy: text {"type":"start","config":{...}} → binary PCM → text {"type":"finish"}
 *   Proxy → Client: text JSON NormalizedASREvent
 *
 * Auth: token passed as ?token=xxx query parameter.
 * URLSessionWebSocketTask buffers send() calls until the connection opens,
 * so start config and early audio frames can be sent immediately after connect().
 */

import Foundation

// MARK: - ASR types

struct ASRSessionConfig: Encodable {
    let language:             String
    let sampleRate:           Int
    let format:               String
    let vocabularyId:         String?
    /// User's own custom hotwords (small list, always sent to server)
    let hotwords:             [String]?
    /// Identity ID — server resolves hotwords from KV instead of sending the full array.
    let identityId:           String?
    /// Pre-generated recording ID for end-to-end tracing
    let recordingId:          String?
    /// True when re-transcribing a saved recording (server may use async file API)
    let retranscribe:         Bool?

    enum CodingKeys: String, CodingKey {
        case language, sampleRate, format, vocabularyId, hotwords, identityId, recordingId, retranscribe
    }
}

struct ASREvent: Decodable {
    let type:          String        // "started" | "result" | "error"
    let isLastPackage: Bool?
    let result:        ASREventResult?
    let error:         String?
    let provider:      String?
    let meta:          ASREventMeta?

    enum CodingKeys: String, CodingKey {
        case type
        case isLastPackage = "is_last_package"
        case result, error, provider, meta
    }
}

struct ASREventMeta: Decodable {
    let resultEventsCount: Int?
}

struct ASREventResult: Decodable {
    let text:       String?
    let utterances: [ASRUtterance]?
}

struct ASRUtterance: Decodable {
    let text:      String
    let definite:  Bool?
    let startTime: Int?
    let endTime:   Int?
}

// MARK: - Error

enum ASRClientError: LocalizedError {
    case connectionFailed
    case timeout
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:      return "ASR connection failed"
        case .timeout:               return "ASR result timeout"
        case .serverError(let msg):  return "ASR server error: \(msg)"
        }
    }
}

// MARK: - ASRClient

/// A single-session ASR WebSocket client. Create a new instance for each recording session.
final class ASRClient {

    // MARK: - Callbacks (set before calling connect)

    /// Called when the ASR session is ready (after session.updated is received).
    var onReady: (() -> Void)?

    /// Called on every non-empty result event (including intermediate results).
    /// Parameters: (text, isFinalPackage)
    var onResult: ((String, Bool) -> Void)?

    /// Called when the WebSocket connection drops unexpectedly (receiveLoop failure).
    /// Fires AFTER the continuation is settled, so waitForFinal will also throw.
    var onDisconnect: ((Error) -> Void)?

    // MARK: - Public state

    /// Number of "result" events received from the ASR backend.
    /// Used to distinguish service errors (0) from genuine no-speech (>0).
    private(set) var resultEventsCount: Int = 0

    /// Whether the last session failure was likely a service error (not genuine silence).
    /// `resultEventsCount == 0` means ASR never processed audio → service issue.
    var isLastResultLikelyServiceError: Bool {
        resultEventsCount == 0
    }

    // MARK: - Private state

    private var task:    URLSessionWebSocketTask?
    private var session: URLSession?

    private let continuationLock  = NSLock()
    private var finalContinuation: CheckedContinuation<String, Error>?

    private var sessionInvalidated = false
    private var receivedFinal = false

    /// Timestamp when connect() was called, used for proxy diagnostics.
    private var connectTime: Date?

    // MARK: - Connect

    /// Connect to the ASR proxy WebSocket. Safe to call sendStart / sendAudio immediately.
    func connect(token: String, baseURL: String) {
        // Build wss:// URL from the https:// base.
        var comps = URLComponents(string: "\(baseURL)/api/v1/asr/proxy")!
        comps.scheme      = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems  = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return }

        // Set connection timeout to avoid hanging indefinitely when server is down.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 30
        // Bypass system proxy (Clash Verge, etc.) for WebSocket stability.
        // Proxies often break long-lived WebSocket connections: HTTP Upgrade
        // incompatibility, mid-session IP switching, and idle timeout kills.
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
        task    = session!.webSocketTask(with: url)
        connectTime = Date()
        task!.resume()
        receiveLoop()
    }

    // MARK: - Send

    /// Send the session start configuration.
    func sendStart(config: ASRSessionConfig) {
        var configDict: [String: Any] = [
            "language":          config.language,
            // Force enable all ASR features (aligned with apps/web cleanup)
            "enableITN":         true,
            "enablePunctuation": true,
            "enableSmoothing":   true,
            "sampleRate":        config.sampleRate,
            "format":            config.format,
        ]
        if let vid = config.vocabularyId, !vid.isEmpty {
            configDict["vocabularyId"] = vid
        }
        if let hw = config.hotwords, !hw.isEmpty {
            configDict["hotwords"] = hw
        }
        if let iid = config.identityId, !iid.isEmpty {
            configDict["identityId"] = iid
        }
        if let rid = config.recordingId {
            configDict["recordingId"] = rid
        }
        if let retranscribe = config.retranscribe {
            configDict["retranscribe"] = retranscribe
        }
        let payload: [String: Any] = ["type": "start", "config": configDict]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str  = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { _ in }
    }

    /// Send a raw PCM audio chunk. Thread-safe; may be called from any thread.
    func sendAudio(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    /// Signal end of audio stream.
    func sendFinish() {
        task?.send(.string(#"{"type":"finish"}"#)) { _ in }
    }

    // MARK: - Wait for final result

    /// Awaits the final ASR result (is_last_package == true).
    /// Resolves with the final text or throws on error / timeout.
    func waitForFinal(timeout: TimeInterval = 8.0) async throws -> String {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: ASRClientError.connectionFailed)
                return
            }
            continuationLock.lock()
            finalContinuation = continuation
            continuationLock.unlock()

            // Timeout task — settles the continuation if the server doesn't reply in time.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.settle(.failure(ASRClientError.timeout))
            }
        }
    }

    // MARK: - Close

    func close() {
        settle(.failure(ASRClientError.connectionFailed))

        // Send close frame with normal closure. URLSession queues the frame
        // internally before completing the cancel — the pending receiveLoop
        // will get a failure AFTER the frame is on the wire, which triggers
        // teardownSession() to invalidate cleanly.
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil

        // Safety: if receiveLoop never fires (e.g. connection already dead),
        // force teardown after 3s to prevent session leak.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.teardownSession()
        }
    }

    // MARK: - Private

    private func settle(_ result: Result<String, Error>) {
        continuationLock.lock()
        let cont = finalContinuation
        finalContinuation = nil
        continuationLock.unlock()
        cont?.resume(with: result)
    }

    /// Invalidate the URLSession exactly once. Called from receiveLoop failure
    /// (normal path) or from the 3s safety timeout (fallback).
    private func teardownSession() {
        continuationLock.lock()
        let alreadyDone = sessionInvalidated
        sessionInvalidated = true
        continuationLock.unlock()
        guard !alreadyDone else { return }

        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let msg):
                if case .string(let text) = msg { self.handleMessage(text) }
                if self.receivedFinal {
                    // Final delivered — stop listening, clean close.
                    self.teardownSession()
                } else {
                    self.receiveLoop()
                }
            case .failure(let error):
                // After final was delivered, any receive failure is expected (server closed).
                guard !self.receivedFinal else {
                    self.teardownSession()
                    return
                }
                self.logProxyDiagnostics(error: error)
                self.settle(.failure(error))
                let cb = self.onDisconnect
                DispatchQueue.main.async { cb?(error) }
                self.teardownSession()
            }
        }
    }

    // MARK: - Proxy diagnostics
    // See docs/proxy-bypass-investigation.md for context.

    /// Proxy-related NSURLError codes that suggest traffic is being intercepted.
    private static let proxyRelatedCodes: Set<Int> = [
        -1004, // kCFURLErrorCannotConnectToHost
        -1005, // kCFURLErrorNetworkConnectionLost
        -1009, // kCFURLErrorNotConnectedToInternet
        -1200, // kCFURLErrorSecureConnectionFailed (TLS through proxy)
         310,  // kCFErrorHTTPSProxyConnectionFailure
    ]

    private func logProxyDiagnostics(error: Error) {
        let nsError = error as NSError
        let alive   = connectTime.map { -$0.timeIntervalSinceNow } ?? -1
        let isProxySuspect = Self.proxyRelatedCodes.contains(nsError.code)

        // Log code 57 (POSIX ENOTCONN) — previously silenced, now tracked for disconnect diagnostics.
        // This fires when the server-side Worker crashes or the TCP connection drops.

        NSLog("[ASR-Proxy-Diag] domain=%@ code=%d alive=%.1fs proxySuspect=%@ desc=%@",
              nsError.domain,
              nsError.code,
              alive,
              isProxySuspect ? "YES" : "NO",
              nsError.localizedDescription)

        if isProxySuspect {
            NSLog("[ASR-Proxy-Diag] WARNING: Connection failure may be proxy-related. " +
                  "If this occurs frequently, see docs/proxy-bypass-investigation.md")
        }
    }

    private func handleMessage(_ text: String) {
        guard let data  = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(ASREvent.self, from: data)
        else { return }

        let resultText  = event.result?.text ?? ""
        let isFinal     = event.isLastPackage ?? false

        // Track result events for service-error detection.
        if event.type == "result" {
            resultEventsCount += 1
        }

        // Update from backend meta if available (authoritative count).
        if let metaCount = event.meta?.resultEventsCount {
            resultEventsCount = metaCount
        }

        // Notify when session is ready (received session.updated from proxy).
        if event.type == "started" {
            let cb = onReady
            DispatchQueue.main.async { cb?() }
        }

        // Deliver intermediate / final result text to the UI.
        if event.type == "result", !resultText.isEmpty {
            let cb = onResult
            DispatchQueue.main.async { cb?(resultText, isFinal) }
        }

        // Settle the continuation when we receive the final package.
        if isFinal {
            receivedFinal = true
            if event.type == "error" {
                settle(.failure(ASRClientError.serverError(event.error ?? "Unknown error")))
            } else {
                settle(.success(resultText))
            }
        }
    }
}
