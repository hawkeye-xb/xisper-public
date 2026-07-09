/**
 * KeyboardMonitor
 *
 * CGEventTap-based keyboard monitor — module-level globals pattern,
 * matching the Electron/dylib architecture exactly.
 *
 * The Electron version (KeyboardEventTap.swift in packages/keyboard-monitor)
 * uses module-level globals + userInfo:nil + direct function calls in the
 * callback. This file mirrors that pattern precisely — no class, no
 * Unmanaged pointer, no extra overhead in the callback path.
 *
 * Debug log: /tmp/xisper-keyboard.log
 */

import AppKit
import CoreGraphics
import Foundation

// MARK: - Module-level state (mirrors Electron's KeyboardEventTap.swift)

private let stateLock = NSLock()

private var tapPort:       CFMachPort?
private var tapRunLoop:    CFRunLoop?
private var tapSource:     CFRunLoopSource?

private var stateCallback: ((Set<String>) -> Void)?
private var doInterceptFn: Bool = false

/// All keys currently held. keyCode → original-case key name.
private var pressingKeys: [Int32: String] = [:]

/// Target shortcut key-sets (lowercased), provided by HotkeySystem.
private var targets: [Set<String>] = []



private let fnSyntheticKeyCode: Int32 = -1

// MARK: - TIS (Globe key mode)

private typealias TISGetFn = @convention(c) () -> Int32
private typealias TISSetFn = @convention(c) (Int32) -> Void
private var _tisGet: TISGetFn?
private var _tisSet: TISSetFn?
private var savedGlobeMode: Int32 = -1

// MARK: - App Nap prevention

private var appNapActivity: NSObjectProtocol?

// MARK: - Debug logging

private let kbLogPath = "/tmp/xisper-keyboard.log"

private func kbLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: kbLogPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: kbLogPath, contents: data)
        }
    }
}

// MARK: - CGEventTap event handler (module-level, no Unmanaged, no pointer)

private func kbDispatchEvent(
    type: CGEventType,
    event: CGEvent
) -> Unmanaged<CGEvent>? {

    // Hold stateLock for the ENTIRE callback body. This prevents data races
    // with start()/updateTargets()/stop() on the main thread, which also
    // hold stateLock when writing pressingKeys, targets, allowedCounts.
    // The lock overhead is negligible — all work inside is pure memory ops.
    stateLock.lock()
    defer { stateLock.unlock() }

    // Re-enable tap if system disabled it.
    // IMPORTANT: clear pressingKeys — while the tap was disabled we missed
    // all key-up events, so any modifier held at that instant is now stale.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        kbLog("tapDisabled: \(type == .tapDisabledByTimeout ? "timeout" : "userInput"), re-enabling + clearing state")
        let hadKeys = !pressingKeys.isEmpty
        pressingKeys = [:]
        if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        if hadKeys { notifyState() }
        return Unmanaged.passRetained(event)
    }

    reconcileWithHardwareState()

    let keyCode  = Int32(event.getIntegerValueField(.keyboardEventKeycode))
    let newFlags = event.flags

    switch type {
    case .flagsChanged:
        return handleFlagsChanged(event: event, keyCode: keyCode,
                                  newFlags: newFlags, interceptFn: doInterceptFn)
    case .keyDown:
        return handleKeyDown(event: event, keyCode: keyCode)
    case .keyUp:
        return handleKeyUp(event: event, keyCode: keyCode)
    default:
        // NSSystemDefined = 14 (CGEventType.systemDefined removed in macOS 26 SDK)
        if type.rawValue == 14 {
            return handleSystemDefined(event: event)
        }
        return Unmanaged.passRetained(event)
    }
}

// MARK: - flagsChanged

private func handleFlagsChanged(
    event: CGEvent, keyCode: Int32,
    newFlags: CGEventFlags, interceptFn: Bool
) -> Unmanaged<CGEvent>? {

    var changed = false

    let isFn  = newFlags.contains(.maskSecondaryFn)
    let hadFn = pressingKeys[fnSyntheticKeyCode] != nil
    if isFn != hadFn {
        if isFn { pressingKeys[fnSyntheticKeyCode] = "FN" }
        else    { pressingKeys.removeValue(forKey: fnSyntheticKeyCode) }
        changed = true
    }

    if let keyName = modifierKeyName(for: keyCode) {
        // Determine press vs release for individual modifier keys.
        // macOS uses shared flags (e.g. maskShift) for left/right pairs.
        // When one shift is released while the other is held, the flag stays set,
        // so we can't rely on the flag alone to detect per-key release.
        //
        // Fix: when the shared flag is CLEAR, the key is definitely released.
        // When the flag is SET, use prior state: if we already tracked this keyCode,
        // this event signals a release (the system only fires flagsChanged for
        // the key that actually changed). If we didn't have it, it's a new press.
        let sharedFlagSet: Bool
        switch keyCode {
        case 0x38, 0x3C: sharedFlagSet = newFlags.contains(.maskShift)
        case 0x3B, 0x3E: sharedFlagSet = newFlags.contains(.maskControl)
        case 0x3A, 0x3D: sharedFlagSet = newFlags.contains(.maskAlternate)
        case 0x37, 0x36: sharedFlagSet = newFlags.contains(.maskCommand)
        default:         sharedFlagSet = false
        }

        let hadKey = pressingKeys[keyCode] != nil
        let isPressed: Bool
        if !sharedFlagSet {
            // Flag is clear → both left and right are released
            isPressed = false
        } else if hadKey {
            // Flag is set but we already track this key → it's being released
            // (the other key of the pair is keeping the flag alive)
            isPressed = false
        } else {
            // Flag is set and we don't have this key → new press
            isPressed = true
        }

        if isPressed != hadKey {
            if isPressed { pressingKeys[keyCode] = keyName }
            else         { pressingKeys.removeValue(forKey: keyCode) }
            changed = true
        }
    }

    // Safety reconciliation: when a shared flag is CLEAR, ensure ALL keys
    // of that type are removed. Catches stuck keys from missed events.
    if !newFlags.contains(.maskShift) {
        if pressingKeys.removeValue(forKey: 0x38) != nil { changed = true }
        if pressingKeys.removeValue(forKey: 0x3C) != nil { changed = true }
    }
    if !newFlags.contains(.maskControl) {
        if pressingKeys.removeValue(forKey: 0x3B) != nil { changed = true }
        if pressingKeys.removeValue(forKey: 0x3E) != nil { changed = true }
    }
    if !newFlags.contains(.maskAlternate) {
        if pressingKeys.removeValue(forKey: 0x3A) != nil { changed = true }
        if pressingKeys.removeValue(forKey: 0x3D) != nil { changed = true }
    }
    if !newFlags.contains(.maskCommand) {
        if pressingKeys.removeValue(forKey: 0x37) != nil { changed = true }
        if pressingKeys.removeValue(forKey: 0x36) != nil { changed = true }
    }

    if changed { notifyState() }
    return (changed && interceptFn && shouldConsume()) ? nil : Unmanaged.passRetained(event)
}

// MARK: - keyDown / keyUp

private func handleKeyDown(event: CGEvent, keyCode: Int32) -> Unmanaged<CGEvent>? {
    guard let keyName = ShortcutKey.keycodeToName[keyCode] else {
        return Unmanaged.passRetained(event)
    }
    // Skip notification on auto-repeat (key already tracked, nothing changed).
    let isNew = pressingKeys[keyCode] == nil
    pressingKeys[keyCode] = keyName
    if isNew { notifyState() }
    return shouldConsume() ? nil : Unmanaged.passRetained(event)
}

private func handleKeyUp(event: CGEvent, keyCode: Int32) -> Unmanaged<CGEvent>? {
    pressingKeys.removeValue(forKey: keyCode)
    notifyState()
    return Unmanaged.passRetained(event)
}

// MARK: - systemDefined (media key trigger)

private func handleSystemDefined(event: CGEvent) -> Unmanaged<CGEvent>? {
    // Quick early-out if media key trigger not enabled
    guard ConfigStore.shared.enableHeadphoneButtonTrigger else {
        return Unmanaged.passRetained(event)
    }

    // Decode via NSEvent for subtype + data1
    guard let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 else {  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        return Unmanaged.passRetained(event)
    }

    let data1     = nsEvent.data1
    let keyCode   = Int32((data1 & 0xFFFF0000) >> 16)
    let keyFlags  = data1 & 0x0000FFFF
    let keyIsDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

    // 16 = NX_KEYTYPE_PLAY
    guard keyCode == 16, keyIsDown else {
        return Unmanaged.passRetained(event)
    }

    // Any play/pause press → toggle recording. Event passes through
    // so the music app also receives it (no device distinction needed).
    DispatchQueue.main.async {
        HotkeySystem.shared.onHeadphoneTrigger()
    }
    return Unmanaged.passRetained(event)
}

// MARK: - Helpers

private func shouldConsume() -> Bool {
    let pressed = Set(pressingKeys.values.map { $0.lowercased() })
    return targets.contains { $0 == pressed }
}

private func notifyState() {
    let snapshot = Set(pressingKeys.values)
    let cb = stateCallback
    DispatchQueue.main.async { cb?(snapshot) }
}

/// Purge phantom keys from `pressingKeys` that are no longer physically held,
/// using the HID system state table (unaffected by Secure Input).
/// Called at the top of every event before recording or matching.
private func reconcileWithHardwareState() {
    for keyCode in pressingKeys.keys {
        if keyCode == fnSyntheticKeyCode { continue }
        if modifierKeyName(for: keyCode) != nil { continue }
        if !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode)) {
            kbLog("reconcile: purged phantom key keyCode=\(keyCode)")
            pressingKeys.removeValue(forKey: keyCode)
        }
    }
}

private func modifierKeyName(for keyCode: Int32) -> String? {
    switch keyCode {
    case 0x38: return "LeftShift"
    case 0x3C: return "RightShift"
    case 0x3B: return "LeftControl"
    case 0x3E: return "RightControl"
    case 0x3A: return "LeftAlt"
    case 0x3D: return "RightAlt"
    case 0x37: return "LeftMeta"
    case 0x36: return "RightMeta"
    case 0x39: return nil          // CapsLock is a toggle, not a held modifier — skip (matches Electron)
    default:   return nil
    }
}

// MARK: - Tap lifecycle

private func kbCreateTap() -> Bool {
    let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)      |
        (1 << CGEventType.keyUp.rawValue)        |
        (1 << CGEventType.flagsChanged.rawValue) |
        (1 << 14)  // NSSystemDefined (CGEventType.systemDefined removed in macOS 26 SDK)

    // userInfo: nil — callback calls module-level function directly
    // This matches the Electron dylib pattern exactly.
    guard let tap = CGEvent.tapCreate(
        tap:              .cghidEventTap,
        place:            .headInsertEventTap,
        options:          .defaultTap,
        eventsOfInterest: eventMask,
        callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
            return kbDispatchEvent(type: type, event: event)
        },
        userInfo: nil
    ) else {
        kbLog("createTap: CGEvent.tapCreate failed (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
        return false
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        kbLog("createTap: CFMachPortCreateRunLoopSource failed")
        CGEvent.tapEnable(tap: tap, enable: false)
        return false
    }

    tapPort   = tap
    tapSource = source

    // Dedicated run-loop thread — identical to Electron
    let sem = DispatchSemaphore(value: 0)
    var capturedRL: CFRunLoop?

    let thread = Thread {
        let rl = CFRunLoopGetCurrent()!
        capturedRL = rl
        sem.signal()
        CFRunLoopAddSource(rl, source, .commonModes)
        CFRunLoopRun()
        CFRunLoopRemoveSource(rl, source, .commonModes)
    }
    thread.name = "com.xisper.keyboard-tap"
    thread.qualityOfService = .userInteractive
    thread.start()

    sem.wait()
    tapRunLoop = capturedRL
    kbLog("createTap: success")
    return true
}

private func kbTeardownTap() {
    guard let tap = tapPort else { return }

    CGEvent.tapEnable(tap: tap, enable: false)

    if let rl = tapRunLoop {
        CFRunLoopStop(rl)
        tapRunLoop = nil
    }
    if let src = tapSource {
        CFRunLoopSourceInvalidate(src)
        tapSource = nil
    }

    tapPort      = nil
    pressingKeys = [:]
    kbLog("teardownTap: done")
}

// MARK: - TIS / Globe key mode

private func loadTIS() {
    guard _tisGet == nil else { return }
    let path = "/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox"
    let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD) ?? dlopen(path, RTLD_NOW)
    guard let handle else { return }
    _tisGet = unsafeBitCast(dlsym(handle, "TISGetFnUsageType"),    to: TISGetFn?.self)
    _tisSet = unsafeBitCast(dlsym(handle, "TISUpdateFnUsageType"), to: TISSetFn?.self)
}

private func globeModeRead() -> Int32 {
    loadTIS()
    return _tisGet?() ?? 2
}

private func globeModeWrite(_ mode: Int32) {
    loadTIS()
    guard let setFn = _tisSet else { return }
    let current = globeModeRead()
    if current == mode { setFn(mode == 0 ? 1 : 0) }
    setFn(mode)
}

private func startGlobeModeSuppression() {
    guard savedGlobeMode == -1 else { return }
    savedGlobeMode = globeModeRead()
    globeModeWrite(0)
}

private func stopGlobeModeSuppression() {
    guard savedGlobeMode != -1 else { return }
    let target = savedGlobeMode
    savedGlobeMode = -1
    globeModeWrite(target)
}

// MARK: - KeyboardMonitor (thin wrapper for HotkeySystem compatibility)

final class KeyboardMonitor {

    static let shared = KeyboardMonitor()

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return tapPort != nil
    }

    @discardableResult
    func start(
        stateCallback callback: @escaping (Set<String>) -> Void,
        targets newTargets: [Set<String>],
        interceptFnKey: Bool
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        stateCallback = callback
        targets = newTargets
        doInterceptFn = interceptFnKey
        pressingKeys = [:]

        if tapPort != nil {
            if interceptFnKey { startGlobeModeSuppression() } else { stopGlobeModeSuppression() }
            return true
        }

        if interceptFnKey { startGlobeModeSuppression() }

        // Prevent App Nap for LSUIElement app
        if appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Global keyboard shortcut monitoring"
            )
            kbLog("App Nap prevention: activity started")
        }

        return kbCreateTap()
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        kbTeardownTap()
        stateCallback = nil
        stopGlobeModeSuppression()

        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    func updateTargets(_ newTargets: [Set<String>], interceptFnKey: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        targets = newTargets
        doInterceptFn = interceptFnKey
        if interceptFnKey { startGlobeModeSuppression() } else { stopGlobeModeSuppression() }
    }

    func getGlobeMode() -> Int32 { globeModeRead() }
    func setGlobeMode(_ mode: Int32) { globeModeWrite(mode) }

    /// Purge phantom keys from `pressingKeys` — call on wake/unlock.
    func reconcile() {
        stateLock.lock()
        defer { stateLock.unlock() }
        reconcileWithHardwareState()
    }
}
