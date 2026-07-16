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
    case refreshFailed
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidCallback: "Invalid OAuth callback"
        case .exchangeFailed:  "Token exchange failed"
        case .refreshFailed:   "Token refresh failed"
        case .notAuthenticated:"Not authenticated"
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

    // MARK: - Environment (delegated to AppEnvironment)

    private var logtoAppId: String { AppEnvironment.logtoAppId }
    private var callbackScheme: String { AppEnvironment.callbackScheme }
    private var redirectURI: String { AppEnvironment.redirectURI }
    var serviceBaseURL: String { AppEnvironment.serviceBaseURL }
    private static let logtoEndpoint = AppEnvironment.logtoEndpoint

    // MARK: - Init

    private init() {
        authLog("AuthManager.init — starting loadStoredTokens")
        loadStoredTokens()
        authLog("AuthManager.init — done, isAuthenticated=\(isAuthenticated)")
        observeSystemWake()
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
            authLog("system wake/unlock (\(note.name.rawValue)) — checking token freshness")

            if let expiryStr = AuthTokenStore.load(key: "token_expiry"),
               let expiry = ISO8601DateFormatter().date(from: expiryStr),
               expiry < Date().addingTimeInterval(120) {
                authLog("system wake — token expired or expiring soon, refreshing via unified path")
                self.refreshInBackground()
            } else {
                authLog("system wake — token still valid, rescheduling timer")
                if let expiryStr = AuthTokenStore.load(key: "token_expiry"),
                   let expiry = ISO8601DateFormatter().date(from: expiryStr) {
                    self.scheduleRefresh(in: Int(expiry.timeIntervalSinceNow))
                }
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
        
        // Only add prompt parameter when forcing re-authentication
        if forceRelogin {
            queryItems.append(.init(name: "prompt", value: "login"))
        }
        
        comps.queryItems = queryItems
        guard let authURL = comps.url else {
            authLog("login() — FAILED to build authURL")
            throw AuthError.invalidCallback
        }
        authLog("login() — opening authorization browser")

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        authLog("login() — waiting for callback URL...")
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
        authLog("login() — received OAuth callback")

        guard let cbComps  = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code      = cbComps.queryItems?.first(where: { $0.name == "code" })?.value,
              let retState  = cbComps.queryItems?.first(where: { $0.name == "state" })?.value,
              retState == state
        else {
            authLog("login() — INVALID callback: state mismatch or missing code")
            throw AuthError.invalidCallback
        }

        authLog("login() — state OK, exchanging authorization code")
        pendingState = nil
        try await exchangeToken(code: code, verifier: verifier)
    }

    func handleAuthCallback(url: URL) {
        authLog("handleAuthCallback() — hasContinuation=\(pendingContinuation != nil)")
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
            _ = try? await URLSession.shared.data(for: req)
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
        }
        authLog("logout() — silent logout completed")
    }

    /// Synchronously returns the stored access token without checking expiry.
    /// Prefer `getValidToken()` in async contexts to ensure the token is fresh.
    func loadToken() -> String? { AuthTokenStore.load(key: "access_token") }

    /// Synchronously reports whether the stored access token is still valid.
    var isTokenValid: Bool {
        guard isAuthenticated,
              AuthTokenStore.load(key: "access_token") != nil,
              let expiryString = AuthTokenStore.load(key: "token_expiry"),
              let expiry = ISO8601DateFormatter().date(from: expiryString)
        else {
            return false
        }
        return expiry > Date()
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

        let (data, httpResp) = try await URLSession.shared.data(for: req)
        let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? -1
        authLog("exchangeToken() — HTTP \(statusCode)")

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
        }
        authLog("exchangeToken() — token file saved, isAuthenticated=true")
    }

    // MARK: - Direct Logto Token Refresh

    /// Public entry point for other managers to trigger token refresh (e.g. on 401).
    /// Goes through the unified deduplicated path to avoid race conditions.
    func refreshAccessToken() async throws {
        _ = try await refreshAndGetToken()
    }

    private func refresh() async throws {
        guard let rt = AuthTokenStore.load(key: "refresh_token"), !rt.isEmpty else {
            authLog("refresh() — no refresh_token (nil or empty), cannot refresh")
            await MainActor.run { isAuthenticated = false }
            throw AuthError.notAuthenticated
        }
        authLog("refresh() — using stored refresh token")

        let url = "\(Self.logtoEndpoint)/oidc/token"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(rt)",
            "client_id=\(logtoAppId)",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, httpResp) = try await URLSession.shared.data(for: req)
        let statusCode = (httpResp as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            authLog("refresh() — FAILED: HTTP \(statusCode)")
            await MainActor.run {
                isAuthenticated = false
                // Clear stale tokens so next cold start doesn't loop on expired credentials
                if statusCode == 400 || statusCode == 401 || statusCode == 403 {
                    AuthTokenStore.clearAll()
                    refreshTimerSource?.cancel()
                    refreshTimerSource = nil
                    userEmail = nil
                    userId    = nil
                    authLog("refresh() — cleared stale tokens (HTTP \(statusCode))")
                }
            }
            throw AuthError.refreshFailed
        }

        let resp = try JSONDecoder().decode(LogtoTokenResponse.self, from: data)
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
    }

    /// **Single entry point for all refresh calls.** Deduplicates concurrent callers
    /// AND retries on transient network errors. Timer, wake observer, on-demand
    /// (`getValidToken`), and external callers all go through here.
    /// This prevents Logto refresh-token rotation races where two concurrent
    /// `refresh()` calls use the same (now-rotated) token and the second gets 400.
    private func refreshAndGetToken() async throws -> String {
        if let existing = activeRefreshTask {
            authLog("refreshAndGetToken() — joining existing task")
            return try await existing.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notAuthenticated }
            defer { self.activeRefreshTask = nil }

            var lastError: Error = AuthError.notAuthenticated
            var backoff: TimeInterval = 2

            for attempt in 0...4 {
                do {
                    try await self.refresh()
                    guard let token = AuthTokenStore.load(key: "access_token") else {
                        throw AuthError.notAuthenticated
                    }
                    if attempt > 0 {
                        authLog("refreshAndGetToken() — succeeded on retry \(attempt)")
                    }
                    return token
                } catch {
                    lastError = error
                    authLog("refreshAndGetToken() — attempt \(attempt) failed: \(error)")
                    if !Self.isRetryableError(error) { break }
                    if attempt < 4 {
                        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        backoff = min(backoff * 2, 30)
                    }
                }
            }
            throw lastError
        }
        activeRefreshTask = task
        return try await task.value
    }

    /// Fire-and-forget refresh via the unified deduplicated path.
    /// Used by the timer and wake observer — they don't need the return value.
    private func refreshInBackground() {
        Task {
            do {
                _ = try await refreshAndGetToken()
                authLog("refreshInBackground() — success")
            } catch {
                authLog("refreshInBackground() — failed: \(error)")
            }
        }
    }

    /// Network errors are retryable; auth errors (400/401/403 from Logto) are not.
    private static func isRetryableError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case AuthError.refreshFailed = error { return false }
        if case AuthError.notAuthenticated = error { return false }
        return true
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
            self?.refreshInBackground()
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
            authLog("  hasRefreshToken=\(!rtk.isEmpty)")
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
            // refreshAndGetToken will set isAuthenticated=false if refresh truly fails.
            isAuthenticated = true
            refreshInBackground()
        }
    }

    private func fetchProfileAndPersist() async {
        guard let token = AuthTokenStore.load(key: "access_token"), !token.isEmpty else { return }
        var req = URLRequest(url: URL(string: "\(serviceBaseURL)/auth/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
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
