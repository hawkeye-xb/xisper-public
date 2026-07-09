/**
 * HotkeySystem
 *
 * Bridges KeyboardMonitor → set-based matching → action callbacks.
 *
 * Two-layer model (aligned with Typeless):
 *   - KeyboardMonitor (native CGEventTap): target ⊆ pressed → consume event.
 *   - HotkeySystem (this file): pressed == target → activate action (toggle).
 *
 * Capture mode routes pressed-key diffs to the Settings UI for recording.
 * 50ms debounce between successive triggers.
 */

import AppKit
import Foundation

// MARK: - Capture event (sent to Settings UI during recording)

struct CaptureKeyEvent {
    let key: String
    enum EventType { case down, up }
    let type: EventType
}

// MARK: - HotkeySystem

@Observable
final class HotkeySystem {

    static let shared = HotkeySystem()

    private(set) var isListening = false
    private(set) var isCaptureMode = false

    /// Settings UI sets this closure to receive raw key events during capture.
    var captureCallback: ((CaptureKeyEvent) -> Void)?

    // Set-based matcher state
    private var targets: [ShortcutTarget] = []
    private var activeShortcut: String?
    private var lastDownTime: UInt64 = 0
    private let debounceNs: UInt64 = 50_000_000 // 50ms
    private var previousPressedKeys: Set<String> = []

    /// Prefix upgrade: after a short shortcut fires (e.g. FN→dictation),
    /// allow upgrading to a longer shortcut (e.g. FN+T→translate) within this window.
    private var upgradeWindowEnd: UInt64 = 0
    private let upgradeWindowNs: UInt64 = 500_000_000 // 500ms
    /// The original (base) shortcut that started the session — used for release detection.
    /// After upgrade FN→FN+T, releasing T shouldn't stop; only releasing FN stops.
    private var baseShortcut: String?

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Reset toggle state + purge phantom keys on any system transition
        let resetHandler: (Notification) -> Void = { [weak self] _ in
            self?.resetMatcher()
            KeyboardMonitor.shared.reconcile()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resetHandler)
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: resetHandler)
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: resetHandler)
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resetHandler)
    }

    // MARK: - Public API

    func start() {
        guard !isListening else { return }
        isListening = true
        buildTargets()
        configureAndStart()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        resetMatcher()
        KeyboardMonitor.shared.stop()
    }

    /// Enter capture mode — raw events forwarded to `captureCallback`.
    func enterCaptureMode() {
        isCaptureMode = true
        resetMatcher()
        KeyboardMonitor.shared.updateTargets([], interceptFnKey: false)
    }

    /// Exit capture mode — resume normal shortcut matching.
    func exitCaptureMode() {
        isCaptureMode = false
        captureCallback = nil
        if isListening {
            buildTargets()
            configureAndStart()
        }
    }

    /// Re-read ShortcutStore and reconfigure interception (call after shortcut save).
    func reloadShortcuts() {
        guard isListening, !isCaptureMode else { return }
        buildTargets()
        configureAndStart()
    }

    // MARK: - Build targets from store

    private func buildTargets() {
        let store = ShortcutStore.shared
        var list: [ShortcutTarget] = []

        for action in store.actions {
            for sc in action.shortcuts {
                if let t = ShortcutTargetParser.parse(actionId: action.id, shortcut: sc) {
                    list.append(t)
                }
            }
        }

        targets = list
    }

    // MARK: - Configure KeyboardMonitor

    private func configureAndStart() {
        let targetSets = targets.map(\.keys)
        let usesFn = targets.contains { $0.keys.contains("fn") }

        _ = KeyboardMonitor.shared.start(
            stateCallback: { [weak self] keys in
                Task { @MainActor [weak self] in
                    self?.handleStateChange(pressedKeys: keys)
                }
            },
            targets: targetSets,
            interceptFnKey: usesFn && ConfigStore.shared.interceptSystemKey
        )
    }

    // MARK: - Set-based state change handler

    @MainActor
    private func handleStateChange(pressedKeys: Set<String>) {
        if isCaptureMode {
            relayCaptureFromDiff(previous: previousPressedKeys, current: pressedKeys)
            previousPressedKeys = pressedKeys
            return
        }

        // Lowercase for matching (targets store lowercased keys)
        let lowered = Set(pressedKeys.map { $0.lowercased() })

        let matched = targets.first { $0.keys == lowered }

        // DEBUG: Log state changes
        CrashLogger.log("HotkeySystem", "handleStateChange — pressed:\(lowered) matched:\(matched?.normalized ?? "nil") active:\(activeShortcut ?? "nil") base:\(baseShortcut ?? "nil")")

        if let matched, activeShortcut == nil {
            // First activation — record upgrade window for prefix shortcuts
            let hasLongerTarget = targets.contains { $0.keys.count > matched.keys.count && matched.keys.isSubset(of: $0.keys) }
            baseShortcut = matched.normalized
            CrashLogger.log("HotkeySystem", "commitDown — shortcut:\(matched.normalized) hasLongerTarget:\(hasLongerTarget)")
            commitDown(matched.normalized)
            if hasLongerTarget {
                upgradeWindowEnd = DispatchTime.now().uptimeNanoseconds + upgradeWindowNs
                CrashLogger.log("HotkeySystem", "upgradeWindow — opened for 500ms")
            }
        } else if activeShortcut != nil {
            // Check for prefix upgrade: a longer shortcut matched within the grace window
            if let matched, matched.normalized != activeShortcut {
                let now = DispatchTime.now().uptimeNanoseconds
                let windowRemaining = upgradeWindowEnd > now ? (upgradeWindowEnd - now) / 1_000_000 : 0
                CrashLogger.log("HotkeySystem", "upgrade check — matched:\(matched.normalized) windowRemaining:\(windowRemaining)ms")
                if now < upgradeWindowEnd {
                    let activeTarget = targets.first { $0.normalized == activeShortcut }
                    if let activeTarget, activeTarget.keys.isSubset(of: matched.keys) {
                        CrashLogger.log("HotkeySystem", "UPGRADE — \(activeTarget.normalized) → \(matched.normalized)")
                        upgradeWindowEnd = 0
                        activeShortcut = matched.normalized
                        upgradeAction(from: activeTarget.normalized, to: matched.normalized)
                    }
                }
            }
            // Release check: use baseShortcut keys (FN), not upgraded shortcut (FN+T).
            // This way releasing T after upgrade doesn't stop recording — only releasing FN does.
            if let base = baseShortcut,
               let baseTarget = targets.first(where: { $0.normalized == base }),
               !baseTarget.keys.isSubset(of: lowered) {
                CrashLogger.log("HotkeySystem", "commitUp — shortcut:\(activeShortcut!) base:\(base)")
                commitUp(activeShortcut!)
            }
        }

        previousPressedKeys = pressedKeys
    }

    // MARK: - Capture relay (diff-based, original case for Settings UI)

    @MainActor
    private func relayCaptureFromDiff(previous: Set<String>, current: Set<String>) {
        guard let cb = captureCallback else { return }
        let added = current.subtracting(previous)
        let removed = previous.subtracting(current)
        for key in added   { cb(.init(key: key, type: .down)) }
        for key in removed { cb(.init(key: key, type: .up)) }
    }

    // MARK: - Commit helpers

    @MainActor
    private func commitDown(_ shortcut: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard activeShortcut == nil, now - lastDownTime >= debounceNs else {
            CrashLogger.log("HotkeySystem", "commitDown BLOCKED — activeShortcut:\(activeShortcut ?? "nil") debounce:\((now - lastDownTime) / 1_000_000)ms")
            return
        }
        activeShortcut = shortcut
        lastDownTime = now
        CrashLogger.log("HotkeySystem", "commitDown SUCCESS — shortcut:\(shortcut)")
        triggerAction(shortcut)
    }

    @MainActor
    private func commitUp(_ shortcut: String) {
        guard activeShortcut == shortcut else {
            CrashLogger.log("HotkeySystem", "commitUp MISMATCH — expected:\(shortcut) active:\(activeShortcut ?? "nil")")
            return
        }
        CrashLogger.log("HotkeySystem", "commitUp SUCCESS — shortcut:\(shortcut)")
        activeShortcut = nil
        baseShortcut = nil
    }

    private func resetMatcher() {
        activeShortcut = nil
        baseShortcut = nil
        lastDownTime = 0
        upgradeWindowEnd = 0
        previousPressedKeys = []
    }

    // MARK: - Prefix upgrade dispatch

    @MainActor
    private func upgradeAction(from oldShortcut: String, to newShortcut: String) {
        let store = ShortcutStore.shared
        guard let newAction = store.actions.first(where: { $0.shortcuts.contains(newShortcut) }) else {
            CrashLogger.log("HotkeySystem", "upgradeAction — no action found for shortcut:\(newShortcut)")
            return
        }

        let coordinator = RecordingCoordinator.shared
        CrashLogger.log("HotkeySystem", "upgradeAction — coordinator.state:\(coordinator.state) newAction:\(newAction.id)")
        if coordinator.state == .recording {
            coordinator.upgradeActionId(newAction.id)
        }
    }

    // MARK: - Headphone button trigger

    @MainActor
    func onHeadphoneTrigger() {
        CrashLogger.log("HotkeySystem", "onHeadphoneTrigger — coordinator.state:\(RecordingCoordinator.shared.state)")

        let coordinator = RecordingCoordinator.shared
        switch coordinator.state {
        case .idle:
            Task { await coordinator.handleKeyPress(actionId: "dictation") }
        case .recording:
            Task { await coordinator.handleKeyRelease() }
        case .finalizing, .committing:
            // Ignore — processing in progress
            break
        }
    }

    // MARK: - Action dispatch

    @MainActor
    private func triggerAction(_ shortcut: String) {
        let store = ShortcutStore.shared
        guard let action = store.actions.first(where: { $0.shortcuts.contains(shortcut) }) else {
            CrashLogger.log("HotkeySystem", "triggerAction — no action for shortcut:\(shortcut)")
            return
        }

        CrashLogger.log("HotkeySystem", "triggerAction — shortcut:\(shortcut) action:\(action.id)")
        switch action.id {
        case "dictation", "translate":
            let coordinator = RecordingCoordinator.shared
            CrashLogger.log("HotkeySystem", "triggerAction — coordinator.state:\(coordinator.state) currentActionId:\(coordinator.currentActionId ?? "nil")")
            switch coordinator.state {
            case .idle:
                CrashLogger.log("HotkeySystem", "triggerAction — calling handleKeyPress with actionId:\(action.id)")
                Task { await coordinator.handleKeyPress(actionId: action.id) }
            case .recording:
                CrashLogger.log("HotkeySystem", "triggerAction — calling handleKeyRelease")
                Task { await coordinator.handleKeyRelease() }
            case .finalizing, .committing:
                CrashLogger.log("HotkeySystem", "triggerAction — IGNORED (processing in progress)")
                break
            }
        default:
            break
        }
    }
}
