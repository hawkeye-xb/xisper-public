import Foundation

/// Privacy-preserving analytics facade for the open-source client.
///
/// The hosted build may replace this implementation at build time. The OSS
/// target never transmits events; the API remains stable so shared product code
/// does not need conditional compilation.
enum Analytics {

    /// UserDefaults key for the opt-out preference (per environment suite).
    static let optOutDefaultsKey = "analytics.optedOut"

    // MARK: - Lifecycle

    static func configure() {}

    // MARK: - Opt-out

    static var isOptedOut: Bool { false }

    static func setOptOut(_ optedOut: Bool) {}

    // MARK: - Identity

    static func identify(userId: String, tier: String) {}
    static func updateTier(_ tier: String) {}
    static func reset() {}

    // MARK: - L0 · Activation funnel

    static func appLaunched(isFirstLaunch: Bool) {}
    static func permissionPrompted(type: String) {}
    static func permissionResult(type: String, granted: Bool) {}
    static func loginStarted() {}
    /// result: "success" | "cancelled" | "error"
    static func loginResult(_ result: String) {}
    static func firstDictationSuccess(secondsSinceLaunch: Int) {}

    // MARK: - L1 · Core dictation loop

    /// mode: "realtime" | "offline"
    static func dictationStarted(sessionId: String, mode: String, identityId: String?) {}
    static func dictationCommitted(sessionId: String, durationMs: Int, latencyMs: Int, charCount: Int, retryCount: Int) {}
    /// phase: "connect" | "stream" | "finalize"
    static func dictationFailed(sessionId: String, errorCode: String, phase: String) {}
    /// via: "autowrite" | "copy"
    static func resultUsed(sessionId: String, via: String) {}

    // MARK: - L2 · Friction & reliability

    /// reason: "disconnect" | "timeout"
    static func dictationRetry(sessionId: String, retryIndex: Int, reason: String) {}
    static func dictationCancelled(sessionId: String, elapsedMs: Int, hadPartial: Bool) {}

    // MARK: - L3 · Feature adoption

    static func identitySwitched(identityId: String) {}
    static func postprocessUsed(sessionId: String, enabled: Bool) {}
    static func mergeCopyUsed(recordCount: Int) {}
    static func retranscribeUsed() {}

    // MARK: - L4 · Monetization

    /// kind: "asr_duration" | "asr_chars" | "llm"
    static func quotaHit(kind: String, tier: String) {}
    /// trigger: "quota" | "settings" | "manual"
    static func upgradeViewed(trigger: String) {}
    static func upgradeClicked(plan: String? = nil) {}
    static func upgradeCompleted(plan: String? = nil) {}

    // MARK: - L5 · Health

    /// `errorCode` must be a code/enum, never a user-facing message string.
    static func error(domain: String, errorCode: String) {}

    // MARK: - L5 · Auth / token-refresh health

    /// trigger ∈ { "timer" | "wake" | "reachability" | "bootstrap" | "reactive_401" | "retry" | "user" }
    static func authRefreshSucceeded(trigger: String) {}
    static func authRefreshTransient(trigger: String, reason: String) {}
    static func authRefreshRejected(trigger: String, status: Int) {}
    static func authLoginRefreshToken(issued: Bool, scope: String?) {}
}
