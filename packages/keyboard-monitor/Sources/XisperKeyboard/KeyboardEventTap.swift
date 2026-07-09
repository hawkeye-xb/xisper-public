/**
 * KeyboardEventTap
 *
 * macOS CGEventTap-based keyboard monitor.
 * Replaces fn-key-monitor (Rust NAPI) + uiohook-napi with a single
 * Swift dylib loaded via koffi FFI — consistent with libXisperContext.
 *
 * Responsibilities:
 *   - Monitor ALL key events (keyDown / keyUp) and modifier changes (flagsChanged)
 *   - Detect FN/Globe key press and release via CGEventFlags.maskSecondaryFn
 *   - Report modifier key events using Carbon Virtual Key Codes
 *   - Suppress Globe emoji popup via HIToolbox TIS private API
 *   - Optionally consume (intercept) configured key events so the system
 *     never sees them (requires Accessibility permission)
 *
 * Event type constants (must match KB_EVENT_* in constants.ts):
 *   1 = KEYDOWN, 2 = KEYUP, 3 = FN_DOWN, 4 = FN_UP
 *
 * Carbon Virtual Key Codes used for modifier keys:
 *   LeftMeta=0x37  RightMeta=0x36  LeftShift=0x38  RightShift=0x3C
 *   LeftAlt=0x3A   RightAlt=0x3D   LeftCtrl=0x3B   RightCtrl=0x3E
 */

import Foundation
import CoreGraphics
import AppKit

// MARK: - Event type constants (mirror KB_EVENT_* in constants.ts)

private let KB_EVENT_KEYDOWN: Int32 = 1
private let KB_EVENT_KEYUP:   Int32 = 2
private let KB_EVENT_FN_DOWN: Int32 = 3
private let KB_EVENT_FN_UP:   Int32 = 4

// MARK: - C-compatible callback type

/// Called by the tap for each relevant key event.
/// - Parameters:
///   - eventType: KB_EVENT_KEYDOWN / KEYUP / FN_DOWN / FN_UP
///   - keyCode:   Carbon Virtual Key Code (0 for FN events)
///   - modifierFlags: lower 32 bits of CGEventFlags at the time of the event
public typealias KeyEventHandler = @convention(c) (Int32, Int32, UInt32) -> Void

// MARK: - Intercept configuration

private struct TapConfig {
  var interceptFnKey: Bool
  var interceptFnKeyCodes: Set<Int32>   // Carbon VKC: consume these when FN is held
  var interceptShortcuts: [(modifierMask: UInt32, keycode: Int32)]  // consume matching combos
}

// MARK: - Global tap state (single-instance dylib, protected by stateLock)

private let stateLock = NSLock()

private var tapPort:       CFMachPort?
private var tapRunLoop:    CFRunLoop?
private var tapSource:     CFRunLoopSource?

private var activeCallback: KeyEventHandler?
private var activeConfig   = TapConfig(interceptFnKey: false, interceptFnKeyCodes: [], interceptShortcuts: [])
private var previousFlags:  CGEventFlags = []

// MARK: - TIS (HIToolbox private API for Globe key mode)

private typealias TISGetFnUsageTypeFn = @convention(c) () -> Int32
private typealias TISSetFnUsageTypeFn = @convention(c) (Int32) -> Void

private var _tisGet: TISGetFnUsageTypeFn? = nil
private var _tisSet: TISSetFnUsageTypeFn? = nil
private var savedGlobeMode: Int32 = -1  // -1 = not saved

private func loadTISFunctions() {
  guard _tisGet == nil else { return }
  let hiToolboxPath = "/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox"
  // RTLD_NOLOAD first to avoid re-loading if already present; fall back to RTLD_NOW
  let handle = dlopen(hiToolboxPath, RTLD_NOW | RTLD_NOLOAD) ?? dlopen(hiToolboxPath, RTLD_NOW)
  guard let handle = handle else { return }
  _tisGet = unsafeBitCast(dlsym(handle, "TISGetFnUsageType"),    to: TISGetFnUsageTypeFn?.self)
  _tisSet = unsafeBitCast(dlsym(handle, "TISUpdateFnUsageType"), to: TISSetFnUsageTypeFn?.self)
}

private func globeModeRead() -> Int32 {
  loadTISFunctions()
  return _tisGet?() ?? 2   // 2 = ShowEmoji (Apple Silicon default)
}

private func globeModeWrite(_ mode: Int32) {
  loadTISFunctions()
  guard let setFn = _tisSet else { return }
  // "Bounce": if already at target, briefly set a different value so TIS
  // posts a change notification and TextInputSwitcher refreshes live state.
  let current = globeModeRead()
  if current == mode {
    setFn(mode == 0 ? 1 : 0)
  }
  setFn(mode)
}

// MARK: - CGEventTap event handler

/// Central dispatcher — called on the CGEventTap run loop thread.
private func dispatchEvent(
  type:  CGEventType,
  event: CGEvent
) -> Unmanaged<CGEvent>? {

  // Re-enable tap if system disabled it (e.g. high-CPU timeout)
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
    return Unmanaged.passRetained(event)
  }

  // Snapshot shared state under lock (avoid holding lock during callback)
  stateLock.lock()
  let cb    = activeCallback
  let cfg   = activeConfig
  let prev  = previousFlags
  stateLock.unlock()

  guard let cb = cb else { return Unmanaged.passRetained(event) }

  let keyCode   = Int32(event.getIntegerValueField(.keyboardEventKeycode))
  let newFlags  = event.flags
  let flagsLow  = UInt32(newFlags.rawValue & 0xFFFF_FFFF)

  switch type {

  case .flagsChanged:
    return handleFlagsChanged(
      event: event, keyCode: keyCode,
      newFlags: newFlags, prevFlags: prev,
      flagsLow: flagsLow, cfg: cfg, cb: cb
    )

  case .keyDown:
    return handleKeyEdge(
      event: event, isDown: true,
      keyCode: keyCode, newFlags: newFlags,
      flagsLow: flagsLow, cfg: cfg, cb: cb
    )

  case .keyUp:
    return handleKeyEdge(
      event: event, isDown: false,
      keyCode: keyCode, newFlags: newFlags,
      flagsLow: flagsLow, cfg: cfg, cb: cb
    )

  default:
    return Unmanaged.passRetained(event)
  }
}

// MARK: - flagsChanged handler

private func handleFlagsChanged(
  event:    CGEvent,
  keyCode:  Int32,
  newFlags: CGEventFlags,
  prevFlags: CGEventFlags,
  flagsLow: UInt32,
  cfg:      TapConfig,
  cb:       KeyEventHandler
) -> Unmanaged<CGEvent>? {

  // Update stored flags immediately
  stateLock.lock()
  previousFlags = newFlags
  stateLock.unlock()

  // ── FN / Globe key ──────────────────────────────────────────────────────
  let wasFn = prevFlags.contains(.maskSecondaryFn)
  let isFn  = newFlags.contains(.maskSecondaryFn)

  if wasFn != isFn {
    if isFn {
      cb(KB_EVENT_FN_DOWN, 0, flagsLow)
    } else {
      cb(KB_EVENT_FN_UP, 0, flagsLow)
    }
    // Consume FN key events when interception is requested
    if cfg.interceptFnKey {
      return nil
    }
    return Unmanaged.passRetained(event)
  }

  // ── Regular modifier keys (Shift / Ctrl / Alt / Meta) ───────────────────
  // keyCode of the flagsChanged event tells us WHICH modifier key changed.
  // The flag bit tells us press (set) vs release (cleared).
  let eventType: Int32
  switch keyCode {
  case 0x38, 0x3C:  // LeftShift, RightShift
    eventType = newFlags.contains(.maskShift)     ? KB_EVENT_KEYDOWN : KB_EVENT_KEYUP
  case 0x3B, 0x3E:  // LeftControl, RightControl
    eventType = newFlags.contains(.maskControl)   ? KB_EVENT_KEYDOWN : KB_EVENT_KEYUP
  case 0x3A, 0x3D:  // LeftAlt/Option, RightAlt/Option
    eventType = newFlags.contains(.maskAlternate) ? KB_EVENT_KEYDOWN : KB_EVENT_KEYUP
  case 0x37, 0x36:  // LeftCommand/Meta, RightCommand/Meta
    eventType = newFlags.contains(.maskCommand)   ? KB_EVENT_KEYDOWN : KB_EVENT_KEYUP
  default:
    // CapsLock (0x39) or other — pass through silently
    return Unmanaged.passRetained(event)
  }

  cb(eventType, keyCode, flagsLow)
  return Unmanaged.passRetained(event)
}

// MARK: - keyDown / keyUp handler

private func handleKeyEdge(
  event:    CGEvent,
  isDown:   Bool,
  keyCode:  Int32,
  newFlags: CGEventFlags,
  flagsLow: UInt32,
  cfg:      TapConfig,
  cb:       KeyEventHandler
) -> Unmanaged<CGEvent>? {

  let eventType = isDown ? KB_EVENT_KEYDOWN : KB_EVENT_KEYUP
  let fnHeld    = newFlags.contains(.maskSecondaryFn)

  // Interception check (keyDown only — never suppress keyUp)
  if isDown {
    // FN + configured key combo → consume
    if fnHeld && cfg.interceptFnKeyCodes.contains(keyCode) {
      cb(eventType, keyCode, flagsLow)
      return nil
    }

    // General modifier+key shortcut → consume when mask matches
    let modBits = UInt32(newFlags.rawValue & 0x00FF_FF00)  // modifier flag bits
    for s in cfg.interceptShortcuts {
      if s.keycode == keyCode && (modBits & s.modifierMask) == s.modifierMask {
        cb(eventType, keyCode, flagsLow)
        return nil
      }
    }
  }

  cb(eventType, keyCode, flagsLow)
  return Unmanaged.passRetained(event)
}

// MARK: - Start / stop helpers

private func startGlobeModeSuppression() {
  guard savedGlobeMode == -1 else { return }
  savedGlobeMode = globeModeRead()
  globeModeWrite(0)  // 0 = Do Nothing (suppress emoji / dictation / input)
}

private func stopGlobeModeSuppression() {
  guard savedGlobeMode != -1 else { return }
  let target = savedGlobeMode
  savedGlobeMode = -1
  globeModeWrite(target)
}

// MARK: - C-exported public API  (xisper_kb_* prefix, consistent with xisper_* naming)

/// Start keyboard monitoring.
///
/// - Parameters:
///   - callback: koffi async callback (called from the tap thread; koffi marshals to V8 thread)
///   - interceptFnKey: consume FN key CGEvents (prevents system emoji / dictation side effects)
///   - interceptFnKeyCodesJson: JSON array of Carbon VKC ints to consume when FN is held
///   - interceptShortcutsJson:  JSON array of {"modifierMask": n, "keycode": n} to consume
/// - Returns: true if the tap was created and the monitor thread started.
@_cdecl("xisper_kb_start")
public func xisperKbStart(
  _ callback:              KeyEventHandler,
  _ interceptFnKey:        Bool,
  _ interceptFnKeyCodesJson: UnsafePointer<CChar>?,
  _ interceptShortcutsJson:  UnsafePointer<CChar>?
) -> Bool {
  stateLock.lock()
  defer { stateLock.unlock() }

  if tapPort != nil {
    // Already running — update callback + config in place
    activeCallback = callback
    activeConfig   = buildConfig(interceptFnKey, interceptFnKeyCodesJson, interceptShortcutsJson)
    if interceptFnKey { startGlobeModeSuppression() }
    return true
  }

  let cfg = buildConfig(interceptFnKey, interceptFnKeyCodesJson, interceptShortcutsJson)
  activeConfig   = cfg
  activeCallback = callback
  previousFlags  = []

  if interceptFnKey { startGlobeModeSuppression() }

  // Event mask: keyDown, keyUp, flagsChanged
  let eventMask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue)      |
    (1 << CGEventType.keyUp.rawValue)        |
    (1 << CGEventType.flagsChanged.rawValue)

  // Create the event tap (kCGHIDEventTap = earliest interception point)
  guard let tap = CGEvent.tapCreate(
    tap:              .cghidEventTap,
    place:            .headInsertEventTap,
    options:          .defaultTap,
    eventsOfInterest: eventMask,
    callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
      return dispatchEvent(type: type, event: event)
    },
    userInfo: nil
  ) else {
    activeCallback = nil
    if interceptFnKey { stopGlobeModeSuppression() }
    return false
  }

  guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    CGEvent.tapEnable(tap: tap, enable: false)
    activeCallback = nil
    if interceptFnKey { stopGlobeModeSuppression() }
    return false
  }

  tapPort   = tap
  tapSource = source

  // Dedicated run-loop thread for the tap
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
  thread.name       = "com.xisper.keyboard-tap"
  thread.qualityOfService = .userInteractive
  thread.start()

  // Wait until the run loop is captured (typically < 1 ms)
  sem.wait()
  tapRunLoop = capturedRL

  return true
}

/// Stop keyboard monitoring and restore Globe key behaviour.
@_cdecl("xisper_kb_stop")
public func xisperKbStop() {
  stateLock.lock()
  defer { stateLock.unlock() }

  guard let tap = tapPort else { return }

  // Disable tap first so no more callbacks fire
  CGEvent.tapEnable(tap: tap, enable: false)

  // Stop the run loop (causes CFRunLoopRun() to return in the tap thread)
  if let rl = tapRunLoop {
    CFRunLoopStop(rl)
    tapRunLoop = nil
  }

  // Invalidate the run-loop source
  if let src = tapSource {
    CFRunLoopSourceInvalidate(src)
    tapSource = nil
  }

  tapPort        = nil
  activeCallback = nil

  stopGlobeModeSuppression()
}

/// Whether the tap is currently running.
@_cdecl("xisper_kb_is_running")
public func xisperKbIsRunning() -> Bool {
  stateLock.lock()
  defer { stateLock.unlock() }
  return tapPort != nil
}

/// Update intercept configuration at runtime (no tap restart required).
@_cdecl("xisper_kb_update_intercept")
public func xisperKbUpdateIntercept(
  _ interceptFnKey:        Bool,
  _ interceptFnKeyCodesJson: UnsafePointer<CChar>?,
  _ interceptShortcutsJson:  UnsafePointer<CChar>?
) {
  stateLock.lock()
  defer { stateLock.unlock() }

  let newCfg = buildConfig(interceptFnKey, interceptFnKeyCodesJson, interceptShortcutsJson)
  activeConfig = newCfg

  if interceptFnKey {
    startGlobeModeSuppression()
  } else {
    stopGlobeModeSuppression()
  }
}

/// Read current AppleFnUsageType (0=DoNothing 1=Input 2=Emoji 3=Dictation).
@_cdecl("xisper_kb_get_globe_mode")
public func xisperKbGetGlobeMode() -> Int32 {
  return globeModeRead()
}

/// Write AppleFnUsageType via TISUpdateFnUsageType (posts TIS change notifications).
@_cdecl("xisper_kb_set_globe_mode")
public func xisperKbSetGlobeMode(_ mode: Int32) {
  globeModeWrite(mode)
}

// MARK: - Config parsing helper

private func buildConfig(
  _ interceptFnKey:          Bool,
  _ fnKeyCodesJson:          UnsafePointer<CChar>?,
  _ shortcutsJson:           UnsafePointer<CChar>?
) -> TapConfig {

  var fnKeyCodes: Set<Int32> = []
  var shortcuts:  [(modifierMask: UInt32, keycode: Int32)] = []

  if let ptr = fnKeyCodesJson,
     let str  = String(cString: ptr, encoding: .utf8),
     let data = str.data(using: .utf8),
     let arr  = try? JSONSerialization.jsonObject(with: data) as? [Int] {
    fnKeyCodes = Set(arr.map { Int32($0) })
  }

  if let ptr = shortcutsJson,
     let str  = String(cString: ptr, encoding: .utf8),
     let data = str.data(using: .utf8),
     let arr  = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
    for item in arr {
      if let mask = item["modifierMask"] as? Int,
         let code = item["keycode"]       as? Int {
        shortcuts.append((modifierMask: UInt32(mask), keycode: Int32(code)))
      }
    }
  }

  return TapConfig(
    interceptFnKey:      interceptFnKey,
    interceptFnKeyCodes: fnKeyCodes,
    interceptShortcuts:  shortcuts
  )
}
