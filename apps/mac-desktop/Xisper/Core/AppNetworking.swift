import Foundation
import Network

// MARK: - AppURLSession
//
// App-wide URLSession configured to WAIT for connectivity instead of failing
// immediately when the network is momentarily unavailable.
//
// This is Apple's built-in answer to the "app woke from sleep before Wi-Fi
// reassociated" problem. With `waitsForConnectivity = true`, URLSession parks
// the request until a usable path appears (up to `timeoutIntervalForResource`)
// rather than throwing `URLError(.notConnectedToInternet)` in the first few
// seconds after wake. This is the single most important change that stops the
// spurious "logged out every time I come home" behaviour.
enum AppURLSession {
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true          // wait for the network, don't insta-fail
        cfg.timeoutIntervalForRequest = 30       // per-request inactivity timeout
        cfg.timeoutIntervalForResource = 60      // overall cap incl. waiting-for-connectivity
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()
}

// MARK: - Network reachability

extension Notification.Name {
    /// Posted (on any thread) when the network path transitions to satisfied.
    static let networkDidBecomeReachable = Notification.Name("com.xisper.networkDidBecomeReachable")
}

/// Lightweight connectivity monitor built on `NWPathMonitor`.
///
/// Answers "is there a usable network path right now?" synchronously, and posts
/// `.networkDidBecomeReachable` when connectivity is restored. Consumers (e.g.
/// `AuthManager`) use the flag to gate proactive work and the notification to
/// retry work that was deferred while offline — without ever mistaking a
/// transient offline window for a permanent auth failure.
final class NetworkReachability: @unchecked Sendable {

    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.xisper.reachability")
    private let lock = NSLock()
    private var _isConnected = true          // optimistic default until first update
    private var started = false

    private init() {}

    /// Synchronous "is the network usable right now?" — a plain flag read.
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    /// Begin monitoring. Idempotent — safe to call more than once.
    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.lock.lock()
            let wasConnected = self._isConnected
            self._isConnected = satisfied
            self.lock.unlock()
            // Only fire on a false→true transition so consumers get a clean
            // "network just came back" edge, not a stream of redundant events.
            if satisfied && !wasConnected {
                NotificationCenter.default.post(name: .networkDidBecomeReachable, object: nil)
            }
        }
        monitor.start(queue: queue)
    }
}
