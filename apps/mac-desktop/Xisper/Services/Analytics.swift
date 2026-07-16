import Foundation

/// Privacy-preserving analytics facade for the open-source client.
///
/// The hosted build may replace this implementation at build time. The OSS
/// target never transmits events; the API remains stable so shared product code
/// does not need conditional compilation.
enum Analytics {
    static func quotaHit(kind: String, tier: String) {}
    static func dictationStarted(sessionId: String, mode: String, identityId: String?) {}
    static func dictationCancelled(sessionId: String, elapsedMs: Int, hadPartial: Bool) {}
    static func dictationFailed(sessionId: String, phase: String, errorCode: String) {}
    static func dictationRetry(sessionId: String, retryIndex: Int, reason: String) {}
    static func dictationCommitted(sessionId: String, durationMs: Int, latencyMs: Int, charCount: Int, retryCount: Int) {}
    static func resultUsed(sessionId: String, via: String) {}
    static func postprocessUsed(sessionId: String, enabled: Bool) {}
    static func firstDictationSuccess(secondsSinceLaunch: Int) {}
}
