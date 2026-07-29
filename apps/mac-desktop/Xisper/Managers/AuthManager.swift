import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - File Logger (temporary debug)

private let authLogFile: URL = {
    let url = URL(fileURLWithPath: "/tmp/\(AppEnvironment.authLogFileName)")
    // Append mode: only create file if it doesn't exist, never truncate.
    // Rotate if > 1 MB to prevent unbounded growth.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? UInt64, size > 1_048_576 {
        let backup = url.appendingPathExtension("prev")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    return url
}()

private func authLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8),
       let fh = try? FileHandle(forWritingTo: authLogFile) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    }
}

// MARK: - Error

enum AuthError: LocalizedError {
    case invalidCallback
    case exchangeFailed
    /// Logto genuinely rejected the refresh token (OAuth `invalid_grant`,
    /// HTTP 400/401/403) or there is no refresh token at all. The credential is
    /// dead — this is the ONLY condition that should force the user back to login.
    case refreshRejected(status: Int)
    /// A recoverable failure that must NOT log the user out: transport error
    /// (URLError), server-side 5xx, 429 rate-limit, 408 timeout, or a malformed
    /// 200 body. Keep the session; retry.
    case refreshTransient(reason: String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidCallback:  "Invalid OAuth callback"
        case .exchangeFailed:   "Token exchange failed"
        case .refreshRejected:  "Token refresh rejected (must re-authenticate)"
        case .refreshTransient: "Token refresh failed transiently (will retry)"
        case .notAuthenticated: "Not authenticated"
        }
    }
}

// MARK: - Logto OIDC token response

private struct LogtoTokenResponse: Decodable {
    let id_token: String
    let access_token: String?
    let refresh_token: String?
    let expires_in: Int
    let token_type: String?
    let scope: String?
}

// MARK: - AuthManager

@Observable
final class AuthManager {

    static let shared = AuthManager()

    private(set) var isAuthenticated = false
    private(set) var userEmail: String?
    private(set) var userId: String?

    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var pendingState: String?
    private var refreshTimerSource: DispatchSourceTimer?
    private var activeRefreshTask: Task<String, Error>?

    /// Guards `activeRefreshTask` so the single-flight check-and-set is atomic
    /// across concurrency domains (AuthManager is not MainActor-isolated, and
    /// the timer + wake observer can both enter refresh at the same instant).
    /// Airtight dedup here is what prevents the refresh-token rotation race
    /// that used to clear all tokens on wake.
    private let refreshLock = NSLock()

    /// A proactive refresh failed on a *transport* error (network not ready).
    /// We keep the user authenticated and retry when connectivity returns.
    private var pendingReachableRefresh = false

    /// Bounded backoff counter for the online-but-flaky retry loop.
    private var transientRetryCount = 0

    /// Debounce for the burst of wake/unlock notifications macOS posts together.
    private var lastWakeHandled = Date.distantPast

    // MARK: - Environment (delegated to AppEnvironment)

    private var logtoAppId: String { AppEnvironment.logtoAppId }
    private var callbackScheme: String { AppEnvironment.callbackScheme }
    private var redirectURI: String { AppEnvironment.redirectURI }
    var serviceBaseURL: String { AppEnvironment.serviceBaseURL }
    private static let logtoEndpoint = AppEnvironment.logtoEndpoint

    // MARK: - Init

    private init() {
        authLog("AuthManager.init — starting loadStoredTokens")
        NetworkReachability.shared.start()
        loadStoredTokens()
        authLog("AuthManager.init — done, isAuthenticated=\(isAuthenticated)")
        observeSystemWake()
        observeNetworkReachable()
    }

    // MARK: - Reachability observer (retry deferred refreshes when network returns)

    /// When the network path comes back, retry a refresh that was deferred
    /// because it failed on a transport error. This is what makes "wake with
    /// Wi-Fi still reconnecting" self-heal instead of dropping to the login screen.
    private func observeNetworkReachable() {
        NotificationCenter.default.addObserver(
            forName: .networkDidBecomeReachable, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isAuthenticated, self.pendingReachableRefresh else { return }
            authLog("network reachable — retrying deferred token refresh")
            self.refreshInBackground(trigger: "reachability")
        }
    }

    // MARK: - Wake observer (belt-and-suspenders alongside DispatchSourceTimer)

    /// Proactively refresh token when system wakes from sleep / screen unlocks.
    /// DispatchSourceTimer(.strict) + wallDeadline handles most cases, but this
    /// catches edge cases where the timer was cancelled or the app was suspended.
    private func observeSystemWake() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        let handler: (Notification) -> Void = { [weak self] note in
            guard let self, self.isAuthenticated else { return }

            // Debounce: macOS posts several of these notifications together on a
            // single wake. Handle the burst once so we don't pile up concurrent
            // refresh calls that could race Logto's refresh-token rotation.
            if Date().timeIntervalSince(self.lastWakeHandled) < 2 { return }
            self.lastWakeHandled = Date()

            authLog("system wake/unlock (\(note.name.rawValue)) — checking token freshness")

            guard let expiryStr = AuthTokenStore.load(key: "token_expiry"),
                  let expiry = ISO8601DateFormatter().date(from: expiryStr) else { return }

            if expiry < Date().addingTimeInterval(120) {
                // Token is expiring. Only fire the refresh if the network is
                // actually usable — throwing a request into a not-yet-reconnected
                // Wi-Fi is exactly what used to fail and force a re-login. If we're
                // offline, defer: the reachability observer retries when it returns.
                if NetworkReachability.shared.isConnected {
                    authLog("system wake — token expiring, network up, refreshing")
                    self.refreshInBackground(trigger: "wake")
                } else {
                    authLog("system wake — token expiring but offline, deferring to reachability")
                    self.pendingReachableRefresh = true
                }
            } else {
                authLog("system wake — token still valid, rescheduling timer")
                self.scheduleRefresh(in: Int(expiry.timeIntervalSinceNow))
            }
        }

        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: handler)
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: handler)
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: handler)
    }

    // MARK: - Public API

    /// Opens the user's default browser for direct Logto PKCE OAuth login.
    /// - Parameter forceRelogin: If true, forces user to enter credentials even if browser session exists
    func login(forceRelogin: Bool = false) async throws {
        cancelLogin()

        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        authLog("login(forceRelogin=\(forceRelogin)) — bundleID=\(bundleID) logtoAppId=\(logtoAppId) callbackScheme=\(callbackScheme)")

        let verifier  = generateVerifier()
        let challenge = generateChallenge(from: verifier)
        let state     = generateState()
        pendingState  = state

        // Build Logto OIDC auth URL directly (no backend intermediary)
        // prompt: omit for SSO (silent if session+consent exists), "login" for forced re-auth
        var comps = URLComponents(string: "\(Self.logtoEndpoint)/oidc/auth")!
        var queryItems: [URLQueryItem] = [
            .init(name: "client_id",             value: logtoAppId),
            .init(name: "redirect_uri",          value: redirectURI),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: "openid profile email offline_access"),
            .init(name: "state",                 value: state),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        
        // Refresh-token guarantee: Logto issues a refresh_token ONLY when
        // `offline_access` is actually CONSENTED. `prompt=consent` forces that
        // grant and is the Logto SDK's own default.
        //
        // CRITICAL: never use `prompt=login`. Logto returns NO refresh_token for
        // it (see the logto-io/js `Prompt` enum: "forcing the user to log in
        // again. Note there'll be no Refresh Token returned in this case."). That
        // silently kills background refresh, so the session dies ~1h later with
        // nothing to refresh — the root cause of the recurring "keeps logging
        // out" bug. `forceRelogin` (Switch Account) therefore also uses consent;
        // truly forcing a different account (ending the Logto SSO session) is a
        // separate follow-up and must NOT reintroduce prompt=login.
        queryItems.append(.init(name: "prompt", value: "consent"))

        comps.queryItems = queryItems
        guard let authURL = comps.url else {
            authLog("login() — FAILED to build authURL")
            throw AuthError.invalidCallback
        }
        authLog("login() — opening authorization URL")

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        authLog("login() — waiting for callback URL...")
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
        authLog("login() — received callback URL")

        guard let cbComps  = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code      = cbComps.queryItems?.first(where: { $0.name == "code" })?.value,
              let retState  = cbComps.queryItems?.first(where: { $0.name == "state" })?.value,
              retState == state
        else {
            authLog("login() — INVALID callback: state mismatch or missing code")
            throw AuthError.invalidCallback
        }

        authLog("login() — state OK, exchanging authorization code with Logto")
        pendingState = nil
        try await exchangeToken(code: code, verifier: verifier)
    }

    func handleAuthCallback(url: URL) {
        authLog("handleAuthCallback() — received callback; hasContinuation=\(pendingContinuation != nil)")
        pendingContinuation?.resume(returning: url)
        pendingContinuation = nil
    }

    func cancelLogin() {
        pendingContinuation?.resume(throwing: CancellationError())
        pendingContinuation = nil
        pendingState = nil
    }

    func logout() async {
        let idToken = AuthTokenStore.load(key: "access_token")

        // 1. Notify backend
        if let token = idToken {
            var req = URLRequest(url: URL(string: "\(serviceBaseURL)/auth/logout")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await AppURLSession.shared.data(for: req)
        }

        // 2. Clear local state (silent logout)
        //    No need to open browser for end_session since login flow uses prompt=login
        await MainActor.run {
            AuthTokenStore.clearAll()
            refreshTimerSource?.cancel()
            refreshTimerSource = nil
            isAuthenticated = false
            userEmail = nil
            userId    = nil
            Analytics.reset()  // stop tying events to the signed-out user
        }
        authLog("logout() — silent logout completed")
    }

    /// Synchronously returns the stored access token without checking expiry.
    /// Prefer `getValidToken()` in async contexts to ensure the token is fresh.
    func loadToken() -> String? { AuthTokenStore.load(key: "access_token") }

    /// Synchronous guard: token exists AND has >60s of life left.
    /// Use this at entry points that must decide instantly (e.g. FN key press).
    /// No network call, no refresh — just a Date() comparison.
    var isTokenValid: Bool {
        guard let expiryStr = AuthTokenStore.load(key: "token_expiry"),
              let expiry = ISO8601DateFormatter().date(from: expiryStr),
              expiry > Date().addingTimeInterval(60)
        else { return false }
        return true
    }

    /// Returns a valid token, automatically refreshing if expired or about to expire.
    /// Multiple concurrent callers share a single refresh to avoid rotation conflicts.
    func getValidToken() async throws -> String {
        // Fast path: token valid and > 60s from expiry
        if let token = AuthTokenStore.load(key: "access_token"),
           let expiryStr = AuthTokenStore.load(key: "token_expiry"),
           let expiry = ISO8601DateFormatter().date(from: expiryStr),
           expiry > Date().addingTimeInterval(60) {
            return token
        }

        // Needs refresh — deduplicate concurrent callers
        return try await refreshAndGetToken()
    }

    /// Resets auth state to unauthenticated (used for navigation)
    func resetAuthState() {
        isAuthenticated = false
    }

    // MARK: - Direct Logto Token Exchange

    private func exchangeToken(code: String, verifier: String) async throws {
        let url = "\(Self.logtoEndpoint)/oidc/token"
        authLog("exchangeToken() — POST \(url)")

        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
            "client_id=\(logtoAppId)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, httpResp) = try await AppURLSession.shared.data(for: req)
        let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? -1
        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        authLog("exchangeToken() — HTTP \(statusCode), responseBytes=\(data.count)")

        guard statusCode == 200 else {
            authLog("exchangeToken() — FAILED: HTTP \(statusCode)")
            throw AuthError.exchangeFailed
        }

        let resp = try JSONDecoder().decode(LogtoTokenResponse.self, from: data)
        let payload = decodeJWTPayload(resp.id_token)

        let hasRefreshToken = resp.refresh_token != nil && !(resp.refresh_token?.isEmpty ?? true)
        authLog("exchangeToken() — SUCCESS email=\(payload["email"] as? String ?? "nil") expiresIn=\(resp.expires_in) hasRefreshToken=\(hasRefreshToken) scope=\(resp.scope ?? "nil")")
        if !hasRefreshToken {
            authLog("⚠️ exchangeToken() — WARNING: Logto did NOT return a refresh_token! Token will expire in \(resp.expires_in)s with no way to refresh. Check Logto app config for offline_access scope.")
        }
        await MainActor.run {
            saveTokensToFile(
                token: resp.id_token,
                refreshToken: resp.refresh_token ?? "",
                expiresIn: resp.expires_in,
                email: payload["email"] as? String,
                userId: payload["sub"] as? String
            )
            isAuthenticated = true
            userEmail = payload["email"] as? String
            userId    = payload["sub"] as? String
            scheduleRefresh(in: resp.expires_in)
            // Analytics: tie events to this user + mark login success.
            if let uid = userId {
                Analytics.identify(userId: uid, tier: UsageManager.shared.tier)
            }
            Analytics.loginResult("success")
            // Surface whether Logto actually issued a refresh token + the granted
            // scope, so refresh-token failures are diagnosable from PostHog alone.
            Analytics.authLoginRefreshToken(issued: hasRefreshToken, scope: resp.scope)
        }
        authLog("exchangeToken() — token file saved, isAuthenticated=true")
    }

    // MARK: - Direct Logto Token Refresh

    /// Public entry point for other managers to trigger token refresh (e.g. on 401).
    /// Goes through the unified deduplicated path to avoid race conditions.
    func refreshAccessToken() async throws {
        _ = try await refreshAndGetToken(trigger: "reactive_401")
    }

    // MARK: - Refresh network call (pure: fetch + classify, no auth-state side effects)
    //
    // CONTRACT: refresh() does exactly two things —
    //   • on success: persists the rotated tokens + reschedules the timer.
    //   • on failure: throws a CLASSIFIED error and touches nothing else.
    // It never flips `isAuthenticated` and never clears tokens. That terminal
    // decision belongs to a single owner (`applyTerminalDecision`, invoked from
    // `refreshAndGetToken`) so the policy "only a genuine invalid_grant logs the
    // user out" lives in exactly one place.
    private func refresh() async throws {
        guard let rt = AuthTokenStore.load(key: "refresh_token"), !rt.isEmpty else {
            // No credential to refresh with — equivalent to a hard rejection.
            authLog("refresh() — no refresh_token (nil or empty)")
            throw AuthError.refreshRejected(status: 0)
        }
        authLog("refresh() — using stored refresh token")

        let url = "\(Self.logtoEndpoint)/oidc/token"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = [
            "grant_type=refresh_token",
            "refresh_token=\(rt)",
            "client_id=\(logtoAppId)",
        ].joined(separator: "&").data(using: .utf8)

        // Transport layer: a URLError here is ALWAYS transient (network not ready
        // after wake, DNS blip, dropped connection). Never a logout.
        let data: Data
        let httpResp: URLResponse
        do {
            (data, httpResp) = try await AppURLSession.shared.data(for: req)
        } catch {
            let code = (error as? URLError)?.errorCode ?? -1
            authLog("refresh() — transport error (transient): \(error)")
            throw AuthError.refreshTransient(reason: "urlerror_\(code)")
        }

        let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? -1

        // Success path.
        if statusCode == 200 {
            guard let resp = try? JSONDecoder().decode(LogtoTokenResponse.self, from: data) else {
                // A 200 with an unparseable body is a server/proxy glitch, not a
                // credential problem — treat as transient, don't nuke the session.
                authLog("refresh() — HTTP 200 but body decode failed (transient)")
                throw AuthError.refreshTransient(reason: "decode_200")
            }
            let payload = decodeJWTPayload(resp.id_token)
            await MainActor.run {
                saveTokensToFile(
                    token: resp.id_token,
                    refreshToken: resp.refresh_token ?? rt,
                    expiresIn: resp.expires_in,
                    email: payload["email"] as? String ?? userEmail,
                    userId: payload["sub"] as? String ?? userId
                )
                isAuthenticated = true
                userEmail = payload["email"] as? String ?? userEmail
                userId    = payload["sub"] as? String ?? userId
                scheduleRefresh(in: resp.expires_in)
            }
            authLog("refresh() — SUCCESS via Logto PKCE, expiresIn=\(resp.expires_in)")
            return
        }

        // Failure path — classify by status code. Body logged for diagnostics only.
        let respBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        if statusCode == 400 || statusCode == 401 || statusCode == 403 {
            // OAuth `invalid_grant`: the refresh token is dead (expired, revoked,
            // or already rotated). This — and ONLY this — is a real logout.
            authLog("refresh() — REJECTED: HTTP \(statusCode), responseBytes=\(data.count)")
            throw AuthError.refreshRejected(status: statusCode)
        } else {
            // 5xx / 429 / 408 / anything else: server-side or transient. The
            // credential is almost certainly fine; keep the session and retry.
            authLog("refresh() — TRANSIENT: HTTP \(statusCode), responseBytes=\(data.count)")
            throw AuthError.refreshTransient(reason: "http_\(statusCode)")
        }
    }

    /// **Single entry point + single decision owner for all refreshes.**
    ///
    /// Deduplicates concurrent callers (single-flight) so a timer-fired refresh
    /// and a wake-observer refresh can never both mint a task and burn the
    /// rotating refresh token twice. Applies the terminal auth-state decision
    /// exactly once, inside the single-flight task:
    ///   • `refreshTransient` → leave `isAuthenticated` untouched, just report.
    ///   • `refreshRejected`  → clear tokens + `isAuthenticated=false` + stop timer.
    ///
    /// Retry policy: one retry on a transient error (2s pause); a rejection fails
    /// immediately with no retry.
    private func refreshAndGetToken(trigger: String = "user") async throws -> String {
        // Airtight single-flight: check-and-set under a lock so a timer-fired
        // refresh and a wake-observer refresh can never both mint a task and
        // burn the (rotating) refresh token twice.
        refreshLock.lock()
        if let existing = activeRefreshTask {
            refreshLock.unlock()
            authLog("refreshAndGetToken() — joining existing task (trigger=\(trigger))")
            return try await existing.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notAuthenticated }
            defer {
                self.refreshLock.lock()
                self.activeRefreshTask = nil
                self.refreshLock.unlock()
            }

            do {
                // First attempt.
                try await self.refresh()
                guard let token = AuthTokenStore.load(key: "access_token") else {
                    throw AuthError.refreshTransient(reason: "no_token_after_refresh")
                }
                Analytics.authRefreshSucceeded(trigger: trigger)
                return token
            } catch AuthError.refreshTransient(let reason) {
                // Transient only: one retry after a short pause. A rejection is
                // never retried — it falls through to the outer catch below.
                authLog("refreshAndGetToken() — transient (\(reason)), retrying once")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                do {
                    try await self.refresh()
                    guard let token = AuthTokenStore.load(key: "access_token") else {
                        throw AuthError.refreshTransient(reason: "no_token_after_retry")
                    }
                    authLog("refreshAndGetToken() — succeeded on retry")
                    Analytics.authRefreshSucceeded(trigger: trigger)
                    return token
                } catch {
                    await self.applyTerminalDecision(error, trigger: trigger)
                    throw error
                }
            } catch {
                // refreshRejected / notAuthenticated — terminal, no retry.
                await self.applyTerminalDecision(error, trigger: trigger)
                throw error
            }
        }
        activeRefreshTask = task
        refreshLock.unlock()
        return try await task.value
    }

    /// The single place that mutates auth state on a failed refresh, and the
    /// single place that emits refresh-failure analytics. Runs once per refresh
    /// cycle (inside the single-flight task) so token-clearing + the logout flip
    /// happen exactly once and events aren't double-counted.
    ///
    /// THE policy, in one function: only `refreshRejected` (genuine invalid_grant)
    /// ever logs the user out. Everything else keeps the session alive.
    private func applyTerminalDecision(_ error: Error, trigger: String) async {
        switch error {
        case AuthError.refreshRejected(let status):
            authLog("applyTerminalDecision() — REJECTED (status=\(status), trigger=\(trigger)): forcing re-auth")
            await MainActor.run {
                AuthTokenStore.clearAll()
                refreshTimerSource?.cancel()
                refreshTimerSource = nil
                isAuthenticated = false
                userEmail = nil
                userId    = nil
            }
            Analytics.authRefreshRejected(trigger: trigger, status: status)
        case AuthError.refreshTransient(let reason):
            authLog("applyTerminalDecision() — TRANSIENT (\(reason), trigger=\(trigger)): staying authenticated")
            Analytics.authRefreshTransient(trigger: trigger, reason: reason)
        default:
            authLog("applyTerminalDecision() — other error (trigger=\(trigger)): \(error)")
            Analytics.authRefreshTransient(trigger: trigger, reason: "other")
        }
    }

    /// Fire-and-forget refresh via the unified path.
    /// Used by the timer, wake observer, reachability observer, and bootstrap.
    ///
    /// Cardinal rule: **a transient error is NOT a logout.** The terminal decision
    /// (clear + re-auth on a genuine rejection, stay signed-in on anything else)
    /// is made inside `refreshAndGetToken` / `applyTerminalDecision`. Here we only
    /// schedule follow-up retries for transient failures.
    private func refreshInBackground(trigger: String) {
        Task {
            do {
                _ = try await refreshAndGetToken(trigger: trigger)
                authLog("refreshInBackground(\(trigger)) — success")
                await MainActor.run {
                    self.pendingReachableRefresh = false
                    self.transientRetryCount = 0
                }
            } catch AuthError.refreshTransient(let reason) {
                // Network not ready / server hiccup — transient. Stay authenticated;
                // retry when connectivity returns or after bounded backoff.
                authLog("refreshInBackground(\(trigger)) — transient (\(reason)), will retry")
                await MainActor.run {
                    self.pendingReachableRefresh = true
                    self.scheduleTransientRetry()
                }
            } catch {
                // refreshRejected / etc. — the credential is genuinely dead and
                // applyTerminalDecision already cleared tokens + flipped
                // isAuthenticated=false. Nothing more to do here.
                authLog("refreshInBackground(\(trigger)) — terminal: \(error)")
            }
        }
    }

    /// Bounded backoff retry for the online-but-flaky case (network path is
    /// satisfied but the refresh still failed, e.g. a Logto hiccup). Caps out
    /// and then leans on the reachability observer / wake handler so we never
    /// spin. Reset on any successful refresh.
    private func scheduleTransientRetry() {
        guard transientRetryCount < 5 else {
            authLog("scheduleTransientRetry() — max attempts, waiting for reachability/wake")
            return
        }
        let delay = min(60, 10 << transientRetryCount)   // 10, 20, 40, 60, 60s
        transientRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
            guard let self, self.isAuthenticated, self.pendingReachableRefresh else { return }
            authLog("scheduleTransientRetry() — retry #\(self.transientRetryCount) after \(delay)s")
            self.refreshInBackground(trigger: "retry")
        }
    }

    /// Schedule the next token refresh using DispatchSourceTimer with `.strict` flag
    /// and `wallDeadline`. Unlike RunLoop-based Timer, this fires reliably even
    /// during App Nap and after macOS sleep — critical for LSUIElement apps.
    private func scheduleRefresh(in expiresIn: Int) {
        refreshTimerSource?.cancel()
        refreshTimerSource = nil

        let delay = max(TimeInterval(expiresIn) - 300, 60)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.refreshInBackground(trigger: "timer")
        }
        refreshTimerSource = timer
        timer.resume()
        authLog("scheduleRefresh() — next refresh in \(Int(delay))s (DispatchSourceTimer.strict + wallDeadline)")
    }

    // MARK: - Token Bootstrap

    private func loadStoredTokens() {
        // Diagnostic: dump full token file state on startup
        let allTokens = AuthTokenStore.readAll()
        let tokenFileExists = FileManager.default.fileExists(atPath: AuthTokenStore.fileURL.path)
        authLog("===== APP LAUNCH — loadStoredTokens() =====")
        authLog("  tokenFileExists=\(tokenFileExists)")
        authLog("  keys=\(allTokens.keys.sorted())")
        authLog("  hasAccessToken=\(allTokens["access_token"] != nil && !(allTokens["access_token"]?.isEmpty ?? true))")
        authLog("  hasRefreshToken=\(allTokens["refresh_token"] != nil && !(allTokens["refresh_token"]?.isEmpty ?? true))")
        authLog("  tokenExpiry=\(allTokens["token_expiry"] ?? "nil")")
        authLog("  email=\(allTokens["email"] ?? "nil")")
        if let rtk = allTokens["refresh_token"], rtk.count > 8 {
            authLog("  hasNonEmptyRefreshToken=true")
        }

        let hasToken = allTokens["access_token"]
        guard let token = hasToken, !token.isEmpty else {
            authLog("  → no access_token, staying unauthenticated")
            return
        }
        userEmail = allTokens["email"]
        userId    = allTokens["user_id"]
        if let expiryStr = allTokens["token_expiry"],
           let expiry    = ISO8601DateFormatter().date(from: expiryStr),
           expiry > Date().addingTimeInterval(60) {
            let remaining = Int(expiry.timeIntervalSinceNow)
            authLog("  → token valid, remaining=\(remaining)s, scheduling refresh")
            isAuthenticated = true
            scheduleRefresh(in: remaining)
            if userEmail == nil { Task { await fetchProfileAndPersist() } }
        } else {
            let expiryStr = allTokens["token_expiry"] ?? "nil"
            authLog("  → token expired (expiry=\(expiryStr)), refreshing via unified path")
            // Optimistically mark as authenticated to avoid flashing login screen.
            // applyTerminalDecision sets isAuthenticated=false only if the refresh
            // token is genuinely rejected; a transient failure keeps us signed in.
            isAuthenticated = true
            refreshInBackground(trigger: "bootstrap")
        }
    }

    private func fetchProfileAndPersist() async {
        guard let token = AuthTokenStore.load(key: "access_token"), !token.isEmpty else { return }
        var req = URLRequest(url: URL(string: "\(serviceBaseURL)/auth/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await AppURLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String ?? json["username"] as? String
        else { return }
        await MainActor.run {
            userEmail = email
            userId = json["userId"] as? String
            var d = AuthTokenStore.readAll()
            d["email"] = email
            if let uid = userId { d["user_id"] = uid }
            AuthTokenStore.writeAll(d)
        }
    }

    // MARK: - Application Support token file

    private func saveTokensToFile(token: String, refreshToken: String, expiresIn: Int, email: String? = nil, userId: String? = nil) {
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        var d = AuthTokenStore.readAll()
        d["access_token"] = token
        d["refresh_token"] = refreshToken
        d["token_expiry"] = ISO8601DateFormatter().string(from: expiry)
        if let email  { d["email"] = email }
        if let userId { d["user_id"] = userId }
        AuthTokenStore.writeAll(d)
        authLog("saveTokensToFile() — saved")
    }

    // MARK: - JWT Payload Decoder

    private func decodeJWTPayload(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: - PKCE Helpers

    private func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private func generateChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Token file (Application Support)

private enum AuthTokenStore {

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(AppEnvironment.appSupportFolderName)
            .appendingPathComponent("auth-tokens.json")
    }

    static func load(key: String) -> String? { readAll()[key] }

    static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    static func writeAll(_ dict: [String: String]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        guard let data = try? JSONEncoder().encode(dict) else {
            authLog("AuthTokenStore.writeAll — encode failed")
            return
        }
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            authLog("AuthTokenStore.writeAll — error: \(error)")
        }
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
        authLog("AuthTokenStore.clearAll() — token file removed")
    }
}

// MARK: - Data Helpers

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
