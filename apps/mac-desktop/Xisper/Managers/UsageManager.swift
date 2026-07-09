/**
 * UsageManager
 *
 * Fetches and caches user quota / usage from GET /api/v1/rate-limit/status.
 * Auto-refreshes every 5 minutes while the app is active.
 *
 * Response shape (from backend):
 *   { success, userId, tier,
 *     llm:  { limit, used, remaining, resetAt, resetIn },
 *     asr:  { duration: { limit, used, remaining },
 *             characters: { limit, used, remaining },
 *             resetAt, resetIn } }
 */

import AppKit
import Foundation

// MARK: - Models

struct QuotaBucket {
    var limit:     Int = 0
    var used:      Int = 0
    var remaining: Int = 0

    var fraction: Double {
        guard limit > 0 else { return 0 }
        return Double(used) / Double(limit)
    }
}

// MARK: - Debug log (DEBUG only)

#if DEBUG
private func usageLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[UsageManager \(ts)] \(msg)")
}
#endif

// MARK: - UsageManager

@Observable
@MainActor
final class UsageManager {

    static let shared = UsageManager()

    private(set) var tier: String = "free"
    private(set) var asrCharacters = QuotaBucket()
    private(set) var asrDuration   = QuotaBucket()   // in seconds
    private(set) var llm           = QuotaBucket()
    private(set) var asrResetAt: Date?
    private(set) var isLoading = false
    private(set) var lastError: String?

    // Subscription info (from rate-limit/status response)
    private(set) var subscriptionStatus: String?        // "active", "canceled", "expired", nil
    private(set) var subscriptionPeriodEnd: Date?       // current billing period end
    private(set) var subscriptionCancelAtPeriodEnd = false

    private var refreshTimer: Timer?
    /// When true, next app-activation triggers an immediate reconcile+refresh, then resets.
    private(set) var awaitingPaymentReturn = false

    private init() {}

    /// Sidebar: unlimited users get a premium identity block — never the finite quota bar (product: “高贵” tier, not metering).
    var isUnlimitedTier: Bool {
        tier.lowercased() == "unlimited"
    }

    /// Character quota bar for free/pro/enterprise (and custom-capped tiers), not for `unlimited`.
    var showsFiniteCharacterQuotaBar: Bool {
        guard asrCharacters.limit > 0, !isUnlimitedTier else { return false }
        return true
    }

    // MARK: - Public

    /// Fetch initial usage on app launch + observe app activation for refresh.
    func startAutoRefresh() {
        #if DEBUG
        usageLog("startAutoRefresh() called")
        #endif
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Refresh on app becoming active (e.g. user returns from browser after payment)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        Task {
            // Reconcile subscription with Creem (once on launch, fire-and-forget)
            await reconcileSubscription()
            // Then fetch usage with reconciled tier
            await refresh()
        }
    }

    /// Only refresh on app-activation when returning from payment flow.
    @objc private func appDidBecomeActive() {
        guard awaitingPaymentReturn else { return }
        awaitingPaymentReturn = false
        #if DEBUG
        usageLog("appDidBecomeActive → payment return detected, reconciling")
        #endif
        Task { await reconcileAndRefresh() }
    }

    /// Set flag so next app-activation triggers a refresh.
    /// Called when user is sent to the payment/pricing page in the browser.
    func markAwaitingPayment() {
        awaitingPaymentReturn = true
    }

    /// Reconcile subscription with payment provider then refresh usage.
    /// Called after payment callback to ensure backend has latest subscription state.
    func reconcileAndRefresh() async {
        await reconcileSubscription()
        await refresh()
    }

    /// Ask backend to reconcile local subscription state with Creem.
    /// Called once on app launch. Non-critical — failures are silently ignored.
    private func reconcileSubscription() async {
        guard let token = try? await AuthManager.shared.getValidToken() else { return }
        let url = "\(serviceBaseURL)/api/v1/subscription/status"
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        #if DEBUG
        usageLog("reconcileSubscription() done")
        #endif
    }

    /// Force a single refresh.
    func refresh() async {
        guard let token = try? await AuthManager.shared.getValidToken() else {
            #if DEBUG
            usageLog("refresh() SKIPPED — no valid token")
            #endif
            CrashLogger.log("UsageManager", "refresh skipped — no valid token")
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let baseURL = serviceBaseURL
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(baseURL)/api/v1/rate-limit/status?_t=\(ts)") else { return }

        #if DEBUG
        usageLog("refresh() → GET \(url.absoluteString)")
        #endif

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            #if DEBUG
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count)B>"
            usageLog("refresh() ← HTTP \(code), body=\(bodyPreview)")
            #endif

            guard code == 200 else {
                lastError = "HTTP \(code)"
                CrashLogger.log("UsageManager", "refresh failed HTTP \(code)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Invalid response"
                CrashLogger.log("UsageManager", "refresh failed — invalid JSON")
                return
            }
            parseResponse(json)
        } catch {
            #if DEBUG
            usageLog("refresh() ERROR: \(error)")
            #endif
            lastError = error.localizedDescription
            CrashLogger.log("UsageManager", "refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// Parse JSON number as Int (handles both Int and Double from JSONSerialization).
    private func jsonInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    private func parseResponse(_ json: [String: Any]) {
        tier = (json["tier"] as? String) ?? "free"

        if let llmDict = json["llm"] as? [String: Any] {
            llm = QuotaBucket(
                limit:     jsonInt(llmDict["limit"]),
                used:      jsonInt(llmDict["used"]),
                remaining: jsonInt(llmDict["remaining"])
            )
        }

        if let asrDict = json["asr"] as? [String: Any] {
            if let dur = asrDict["duration"] as? [String: Any] {
                asrDuration = QuotaBucket(
                    limit:     jsonInt(dur["limit"]),
                    used:      jsonInt(dur["used"]),
                    remaining: jsonInt(dur["remaining"])
                )
            }
            if let chars = asrDict["characters"] as? [String: Any] {
                asrCharacters = QuotaBucket(
                    limit:     jsonInt(chars["limit"]),
                    used:      jsonInt(chars["used"]),
                    remaining: jsonInt(chars["remaining"])
                )
            }
            if let resetStr = asrDict["resetAt"] as? String {
                asrResetAt = ISO8601DateFormatter().date(from: resetStr)
            }
        }

        // Parse subscription info
        if let subDict = json["subscription"] as? [String: Any] {
            subscriptionStatus = subDict["status"] as? String
            subscriptionCancelAtPeriodEnd = (subDict["cancelAtPeriodEnd"] as? Bool) ?? false
            if let periodEndMs = subDict["currentPeriodEnd"] as? Double, periodEndMs > 0 {
                subscriptionPeriodEnd = Date(timeIntervalSince1970: periodEndMs / 1000.0)
            } else {
                subscriptionPeriodEnd = nil
            }
        } else {
            subscriptionStatus = nil
            subscriptionPeriodEnd = nil
            subscriptionCancelAtPeriodEnd = false
        }

        #if DEBUG
        usageLog("parsed → tier=\(tier) asr.chars=\(asrCharacters.used)/\(asrCharacters.limit) asr.dur=\(asrDuration.used)/\(asrDuration.limit) sub=\(subscriptionStatus ?? "nil") cancelAtEnd=\(subscriptionCancelAtPeriodEnd)")
        #endif
        CrashLogger.log("UsageManager", "parsed: tier=\(tier) asr.chars=\(asrCharacters.used)/\(asrCharacters.limit) asr.dur=\(asrDuration.used)/\(asrDuration.limit)")
    }

    /// Human-readable reset time label, e.g. "in 2d 5h".
    var resetLabel: String {
        guard let reset = asrResetAt else { return "soon" }
        let diff = reset.timeIntervalSinceNow
        guard diff > 0 else { return "soon" }
        let h = Int(diff) / 3600
        let d = h / 24
        let rem = h % 24
        if d > 0 { return "in \(d)d \(rem)h" }
        if h > 0 { return "in \(h)h" }
        let m = Int(diff) / 60
        return "in \(m)m"
    }

    private var serviceBaseURL: String { AppEnvironment.serviceBaseURL }
}
