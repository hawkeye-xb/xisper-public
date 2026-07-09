import AppKit
import Carbon
import SwiftUI

/// NSApplicationDelegate:
///   • Creates the main window manually (fullSizeContentView in styleMask from birth).
///   • Handles xisper:// URL callbacks for the browser-based OAuth flow.
///   • Prevents the app from quitting when the main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton access (NSApp.delegate cast fails inside MenuBarExtra)
    static private(set) var shared: AppDelegate?

    // MARK: - Main window

    /// Retained reference — window is not released on close (LSUIElement app).
    var mainWindow: NSWindow?

    /// Bring the main window to front.
    /// Handles the case where the window was closed (not visible) by
    /// re-setting the activation policy to `.regular` so macOS treats the app
    /// as a foreground app again.
    func openMainWindow(forceActivate: Bool = false) {
        let policy = NSApp.activationPolicy()
        let hasWindow = mainWindow != nil
        let isVisible = mainWindow?.isVisible ?? false
        appendLog("openMainWindow — window=\(hasWindow) visible=\(isVisible) policy=\(policy.rawValue)")

        guard let window = mainWindow else {
            appendLog("openMainWindow — mainWindow is nil, cannot open")
            return
        }

        // LSUIElement app: re-assert regular policy so activate works after window was closed.
        if policy != .regular {
            NSApp.setActivationPolicy(.regular)
            appendLog("openMainWindow — reset activationPolicy to .regular")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appendLog("openMainWindow — done, isVisible=\(window.isVisible)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Apply language override BEFORE any UI/localized string is loaded.
        LanguageManager.applySwizzle()

        // Configure Sparkle updater check interval (2 hours for faster critical update delivery)
        XisperApp.configureUpdater()

        // Switch to regular policy so the main window is assigned a fixed Space
        // and doesn't follow the user into fullscreen apps.
        // The bubble panel keeps its own .canJoinAllSpaces + .statusBar level config.
        NSApp.setActivationPolicy(.regular)

        restoreAppearance()
        SoundEffects.warmUp()
        BubblePanelManager.shared.startObserving()

        // ── Register URL handler ──
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // ── Create main window ──
        // fullSizeContentView is in the style mask at construction time, exactly
        // like Electron's titleBarStyle:'hiddenInset'.  SwiftUI's first layout
        // already sees the correct safe-area (≈28pt), and ignoresSafeArea(.top)
        // in ContentView extends content to y=0 from the very first frame.
        
        // Calculate centered initial position
        let initialWidth: CGFloat = 1200
        let initialHeight: CGFloat = 800
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let centerX = screenFrame.origin.x + (screenFrame.width - initialWidth) / 2
        let centerY = screenFrame.origin.y + (screenFrame.height - initialHeight) / 2
        
        let window = NSWindow(
            contentRect: NSRect(x: centerX, y: centerY, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        // Stay in its own Space, never float above fullscreen apps.
        // .managed = participates in Exposé/Mission Control normally.
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.level = .normal

        let hosting = NSHostingController(
            rootView: ContentView()
                .modelContainer(XisperApp.modelContainer)
        )
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        
        // Media key trigger — the CGEventTap handles this directly.
        // No IOHIDManager needed; KeyboardMonitor listens for all
        // NSSystemDefined play/pause events and routes to HotkeySystem.
        
        // Debug: log traffic light button positions
        DispatchQueue.main.async {
            self.logTrafficLightPositions(window)
        }
    }

    // MARK: - URL scheme

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? "<nil>"
        appendLog("AppDelegate.handleGetURL — raw urlString=\(urlString)")

        guard
            let url = URL(string: urlString),
            url.scheme?.hasPrefix("xisper") == true
        else {
            appendLog("AppDelegate.handleGetURL — IGNORED (not xisper scheme)")
            return
        }

        // Route by path: auth callback vs payment success
        let path = url.host ?? url.path  // xisper-mac://payment-success → host = "payment-success"
        if path == "payment-success" {
            appendLog("AppDelegate.handleGetURL — payment success callback")
            Task { @MainActor in PaymentManager.shared.handlePaymentCallback() }
        } else {
            appendLog("AppDelegate.handleGetURL — forwarding to AuthManager")
            AuthManager.shared.handleAuthCallback(url: url)
        }

        // Bring app + main window to front after callback.
        openMainWindow(forceActivate: true)
    }

    private func appendLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        print(line, terminator: "")
        let url = URL(fileURLWithPath: "/tmp/xisper-auth.log")
        if let data = line.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }

    // MARK: - Window lifecycle

    private func restoreAppearance() {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        switch style {
        case "Dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        default:      NSApp.appearance = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running when the window is closed; tray icon keeps the app alive.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow(forceActivate: true)
        }
        return true
    }
    
    // MARK: - Debug helper
    
    private func logTrafficLightPositions(_ window: NSWindow) {
        var log = "\n=== Traffic Light Button Positions ===\n"
        
        if let closeButton = window.standardWindowButton(.closeButton) {
            let frame = closeButton.frame
            log += "Close:     x=\(frame.origin.x), y=\(frame.origin.y), width=\(frame.width), height=\(frame.height)\n"
        }
        
        if let miniaturizeButton = window.standardWindowButton(.miniaturizeButton) {
            let frame = miniaturizeButton.frame
            log += "Minimize:  x=\(frame.origin.x), y=\(frame.origin.y), width=\(frame.width), height=\(frame.height)\n"
        }
        
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            let frame = zoomButton.frame
            log += "Zoom:      x=\(frame.origin.x), y=\(frame.origin.y), width=\(frame.width), height=\(frame.height)\n"
        }
        
        log += "Window content frame: \(window.contentView?.frame ?? .zero)\n"
        log += "Window level raw: \(window.level.rawValue)  (normal=0)\n"
        log += "Window collectionBehavior raw: \(window.collectionBehavior.rawValue)\n"
        // Decode collectionBehavior flags
        let cb = window.collectionBehavior
        var flags: [String] = []
        if cb.contains(.managed)               { flags.append("managed") }
        if cb.contains(.participatesInCycle)   { flags.append("participatesInCycle") }
        if cb.contains(.canJoinAllSpaces)      { flags.append("⚠️ canJoinAllSpaces") }
        if cb.contains(.moveToActiveSpace)     { flags.append("⚠️ moveToActiveSpace") }
        if cb.contains(.stationary)            { flags.append("stationary") }
        if cb.contains(.transient)             { flags.append("transient") }
        if cb.contains(.ignoresCycle)          { flags.append("ignoresCycle") }
        if cb.contains(.fullScreenPrimary)     { flags.append("fullScreenPrimary") }
        if cb.contains(.fullScreenAuxiliary)   { flags.append("fullScreenAuxiliary") }
        log += "Window collectionBehavior flags: [\(flags.joined(separator: ", "))]\n"
        log += "NSApp.activationPolicy: \(NSApp.activationPolicy().rawValue)  (regular=0, accessory=1, prohibited=2)\n"
        log += "======================================\n"
        
        print(log)
        appendLog(log)
    }
}
