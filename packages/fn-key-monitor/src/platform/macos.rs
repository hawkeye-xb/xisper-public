//! macOS CGEventTap implementation for FN key monitoring
//!
//! This module uses the Core Graphics Event Tap API to monitor keyboard events
//! and detect FN key press/release.

use std::collections::HashSet;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use core_foundation::base::TCFType;
use core_foundation::runloop::{
    kCFRunLoopCommonModes, CFRunLoop, CFRunLoopGetCurrent, CFRunLoopRun, CFRunLoopStop,
};
use parking_lot::Mutex;

/// Callback type for FN key state changes
/// `true` = pressed, `false` = released
pub type FnKeyCallback = Box<dyn Fn(bool) + Send + Sync + 'static>;

// The secondary fn key flag (0x800000 = NX_SECONDARYFNMASK)
const FN_KEY_MASK: u64 = 0x800000;
const SHIFT_MASK: u64 = 0x20000;
const CONTROL_MASK: u64 = 0x40000;
const ALTERNATE_MASK: u64 = 0x80000;
const COMMAND_MASK: u64 = 0x100000;
const ALL_MODIFIER_MASK: u64 =
    SHIFT_MASK | CONTROL_MASK | ALTERNATE_MASK | COMMAND_MASK | FN_KEY_MASK;

// CGEventTap types and constants
type CGEventTapLocation = u32;
type CGEventTapPlacement = u32;
type CGEventTapOptions = u32;
type CGEventMask = u64;
type CGEventRef = *mut c_void;
type CFMachPortRef = *mut c_void;
type CGEventTapProxy = *mut c_void;
type CFRunLoopSourceRef = *mut c_void;
type CFRunLoopRef = *mut c_void;

const K_CG_HID_EVENT_TAP: CGEventTapLocation = 0;
const K_CG_HEAD_INSERT_EVENT_TAP: CGEventTapPlacement = 0;
const K_CG_EVENT_TAP_OPTION_DEFAULT: CGEventTapOptions = 0;
const K_CG_EVENT_TAP_OPTION_LISTEN_ONLY: CGEventTapOptions = 1;
const K_CG_EVENT_KEY_DOWN: u32 = 10;
const K_CG_EVENT_KEY_UP: u32 = 11;
const K_CG_EVENT_FLAGS_CHANGED: u32 = 12;
/// CGEventField for keyboard virtual keycode (kCGKeyboardEventKeycode in CGEventTypes.h)
const K_CG_KEYBOARD_EVENT_KEYCODE: u32 = 9;
/// Virtual key code for Fn/Globe key (some keyboards send as key event, not only modifier)
const KVK_FUNCTION: i64 = 63;

// CGEventTap callback type
type CGEventTapCallBack = extern "C" fn(
    proxy: CGEventTapProxy,
    event_type: u32,
    event: CGEventRef,
    user_info: *mut c_void,
) -> CGEventRef;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(
        tap: CGEventTapLocation,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        events_of_interest: CGEventMask,
        callback: CGEventTapCallBack,
        user_info: *mut c_void,
    ) -> CFMachPortRef;

    fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    fn CGEventGetFlags(event: CGEventRef) -> u64;
    fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFMachPortCreateRunLoopSource(
        allocator: *const c_void,
        port: CFMachPortRef,
        order: i64,
    ) -> CFRunLoopSourceRef;

    fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: *const c_void);
}

/// macOS event tap for monitoring FN key
pub struct MacOSEventTap {
    callback: Arc<Mutex<Option<FnKeyCallback>>>,
    intercept_system: bool,
    intercept_fn_key: bool,
    intercept_key_codes: HashSet<i64>,
    intercept_shortcuts: Vec<(u64, i64)>,
    is_running: Arc<AtomicBool>,
    run_loop: Arc<Mutex<Option<CFRunLoop>>>,
    previous_fn_state: Arc<AtomicBool>,
    /// True while a Globe KEY_DOWN has been consumed and the matching FLAGS_CHANGED(fn=false)
    /// has not yet been consumed. Guards against the case where KEY_UP resets previous_fn_state
    /// before FLAGS_CHANGED(fn=false) arrives, which would otherwise let that event pass through
    /// to the system and re-arm the emoji picker.
    fn_key_intercepted: Arc<AtomicBool>,
}

impl MacOSEventTap {
    /// Create a new macOS event tap. Only blocks events that match the whitelist (intercept_fn_key, intercept_key_codes).
    pub fn new<F>(
        callback: F,
        intercept_system: bool,
        intercept_fn_key: bool,
        intercept_key_codes: HashSet<i64>,
        intercept_shortcuts: Vec<(u64, i64)>,
    ) -> Result<Self, String>
    where
        F: Fn(bool) + Send + Sync + 'static,
    {
        Ok(Self {
            callback: Arc::new(Mutex::new(Some(Box::new(callback)))),
            intercept_system,
            intercept_fn_key,
            intercept_key_codes,
            intercept_shortcuts,
            is_running: Arc::new(AtomicBool::new(false)),
            run_loop: Arc::new(Mutex::new(None)),
            previous_fn_state: Arc::new(AtomicBool::new(false)),
            fn_key_intercepted: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Start the event tap
    pub fn start(&self) -> Result<(), String> {
        if self.is_running.load(Ordering::SeqCst) {
            return Err("Event tap is already running".to_string());
        }

        let callback = Arc::clone(&self.callback);
        let intercept_system = self.intercept_system;
        let intercept_fn_key = self.intercept_fn_key;
        let intercept_key_codes = self.intercept_key_codes.clone();
        let intercept_shortcuts = self.intercept_shortcuts.clone();
        let is_running = Arc::clone(&self.is_running);
        let run_loop_holder = Arc::clone(&self.run_loop);
        let previous_fn_state = Arc::clone(&self.previous_fn_state);
        let fn_key_intercepted = Arc::clone(&self.fn_key_intercepted);

        // Spawn a thread to run the event tap
        thread::spawn(move || {
            let callback_data = CallbackData {
                callback,
                intercept_system,
                intercept_fn_key,
                intercept_key_codes,
                intercept_shortcuts,
                previous_fn_state,
                fn_key_intercepted,
            };
            let callback_data = Box::new(callback_data);
            let callback_ptr = Box::into_raw(callback_data) as *mut c_void;

            // Listen for flags-changed (FN as modifier) and key-down/up (FN/Globe as physical key, and FN+other keys)
            let event_mask: CGEventMask =
                (1 << K_CG_EVENT_FLAGS_CHANGED) | (1 << K_CG_EVENT_KEY_DOWN) | (1 << K_CG_EVENT_KEY_UP);

            let tap_options = if intercept_system {
                K_CG_EVENT_TAP_OPTION_DEFAULT
            } else {
                K_CG_EVENT_TAP_OPTION_LISTEN_ONLY
            };

            let event_tap = unsafe {
                CGEventTapCreate(
                    K_CG_HID_EVENT_TAP,
                    K_CG_HEAD_INSERT_EVENT_TAP,
                    tap_options,
                    event_mask,
                    event_tap_callback,
                    callback_ptr,
                )
            };

            if event_tap.is_null() {
                // Clean up callback data
                unsafe {
                    drop(Box::from_raw(callback_ptr as *mut CallbackData));
                }
                eprintln!("Failed to create event tap. Make sure Accessibility permission is granted.");
                return;
            }

            // Create a run loop source
            let run_loop_source = unsafe {
                CFMachPortCreateRunLoopSource(std::ptr::null(), event_tap, 0)
            };

            if run_loop_source.is_null() {
                unsafe {
                    drop(Box::from_raw(callback_ptr as *mut CallbackData));
                }
                eprintln!("Failed to create run loop source");
                return;
            }

            // Get the current run loop
            let run_loop = unsafe { CFRunLoopGetCurrent() };

            // Add the source to the run loop
            unsafe {
                CFRunLoopAddSource(
                    run_loop as CFRunLoopRef,
                    run_loop_source,
                    kCFRunLoopCommonModes as *const c_void,
                );
            }

            // Enable the event tap
            unsafe {
                CGEventTapEnable(event_tap, true);
            }

            // Store the run loop for later stopping
            {
                let cf_run_loop = unsafe { CFRunLoop::wrap_under_get_rule(run_loop) };
                let mut holder = run_loop_holder.lock();
                *holder = Some(cf_run_loop);
            }

            is_running.store(true, Ordering::SeqCst);

            // Run the loop
            unsafe {
                CFRunLoopRun();
            }

            // Cleanup
            is_running.store(false, Ordering::SeqCst);
            unsafe {
                drop(Box::from_raw(callback_ptr as *mut CallbackData));
            }
        });

        // Wait a bit for the thread to start
        thread::sleep(std::time::Duration::from_millis(50));

        if self.is_running.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err("Failed to start event tap".to_string())
        }
    }

    /// Stop the event tap
    pub fn stop(&self) {
        if !self.is_running.load(Ordering::SeqCst) {
            return;
        }

        // Stop the run loop
        let run_loop = {
            let mut holder = self.run_loop.lock();
            holder.take()
        };

        if let Some(rl) = run_loop {
            unsafe {
                CFRunLoopStop(rl.as_concrete_TypeRef());
            }
        }

        // Clear the callback
        {
            let mut cb = self.callback.lock();
            *cb = None;
        }
    }

    /// Check if the event tap is running
    #[allow(dead_code)]
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::SeqCst)
    }
}

impl Drop for MacOSEventTap {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Internal callback data structure
struct CallbackData {
    callback: Arc<Mutex<Option<FnKeyCallback>>>,
    intercept_system: bool,
    intercept_fn_key: bool,
    intercept_key_codes: HashSet<i64>,
    intercept_shortcuts: Vec<(u64, i64)>,
    previous_fn_state: Arc<AtomicBool>,
    /// Tracks that a Globe KEY_DOWN was consumed; cleared by the subsequent FLAGS_CHANGED(fn=false).
    fn_key_intercepted: Arc<AtomicBool>,
}

// kCGEventTapDisabledByTimeout / kCGEventTapDisabledByUserInput — macOS auto-disables taps
// that are too slow; these sentinel values arrive instead of a real event.
const K_CG_EVENT_TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFFFFFE;
const K_CG_EVENT_TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFFFFFF;

/// CGEventTap callback function
extern "C" fn event_tap_callback(
    proxy: CGEventTapProxy,
    event_type: u32,
    event: CGEventRef,
    user_info: *mut c_void,
) -> CGEventRef {
    if user_info.is_null() {
        return event;
    }

    let callback_data = unsafe { &*(user_info as *const CallbackData) };

    // ── Tap-disabled re-enable ──────────────────────────────────────────────
    // macOS disables an event tap if the callback is too slow. Re-enable it so
    // we keep intercepting Globe events even after a brief overload.
    if event_type == K_CG_EVENT_TAP_DISABLED_BY_TIMEOUT
        || event_type == K_CG_EVENT_TAP_DISABLED_BY_USER_INPUT
    {
        // proxy here is the CFMachPortRef of the tap (the API guarantees this for
        // disabled-tap callbacks), so we can re-enable directly.
        unsafe { CGEventTapEnable(proxy as CFMachPortRef, true) };
        return event;
    }

    // Key-down or key-up: only block/strip when event matches user-configured shortcuts
    if event_type == K_CG_EVENT_KEY_DOWN || event_type == K_CG_EVENT_KEY_UP {
        let keycode = unsafe { CGEventGetIntegerValueField(event, K_CG_KEYBOARD_EVENT_KEYCODE) };
        if callback_data.intercept_system {
            if keycode == KVK_FUNCTION && callback_data.intercept_fn_key {
                // User has "FN" shortcut: suppress FN key so system doesn't get it (e.g. double-tap emoji).
                // Only fire callback if state actually changed — prevents double-fire on Globe Macs that
                // send both a KEY_DOWN (keycode=63) and a FLAGS_CHANGED for the same physical press.
                let new_state = event_type == K_CG_EVENT_KEY_DOWN;
                let was_pressed = callback_data
                    .previous_fn_state
                    .swap(new_state, Ordering::SeqCst);
                if was_pressed != new_state {
                    if let Some(ref cb) = *callback_data.callback.lock() {
                        cb(new_state);
                    }
                }
                // On Globe KEY_DOWN, mark that we have an in-flight interception so that the
                // subsequent FLAGS_CHANGED(fn=false) on release is also consumed even when KEY_UP
                // fires first and resets previous_fn_state to false before FLAGS_CHANGED arrives.
                if new_state {
                    callback_data.fn_key_intercepted.store(true, Ordering::SeqCst);
                }
                return std::ptr::null_mut();
            }
            let flags = unsafe { CGEventGetFlags(event) };
            // FN+key combos: use internal FN state (not event flags) because
            // consuming FN flagsChanged prevents the system from setting FN_KEY_MASK
            let fn_is_down = callback_data.previous_fn_state.load(Ordering::SeqCst)
                || (flags & FN_KEY_MASK) != 0;
            if !callback_data.intercept_key_codes.is_empty()
                && fn_is_down
                && callback_data.intercept_key_codes.contains(&keycode)
            {
                return std::ptr::null_mut();
            }
            // Non-FN shortcut combos: consume entirely
            if !callback_data.intercept_shortcuts.is_empty() {
                let current_mods = flags & ALL_MODIFIER_MASK;
                for &(required_mods, required_keycode) in &callback_data.intercept_shortcuts {
                    if current_mods == required_mods && keycode == required_keycode {
                        return std::ptr::null_mut();
                    }
                }
            }
        }
        return event;
    }

    // Flags-changed: FN reported as modifier (e.g. older keyboards). Only suppress if user has "FN" shortcut.
    if event_type != K_CG_EVENT_FLAGS_CHANGED {
        return event;
    }

    let flags = unsafe { CGEventGetFlags(event) };
    let fn_pressed = (flags & FN_KEY_MASK) != 0;
    let prev_fn_state = callback_data
        .previous_fn_state
        .swap(fn_pressed, Ordering::SeqCst);

    if fn_pressed != prev_fn_state {
        if let Some(ref cb) = *callback_data.callback.lock() {
            cb(fn_pressed);
        }
    }

    // Consume FLAGS_CHANGED whenever FN is currently down, was just released, OR we have an
    // in-flight Globe interception (fn_key_intercepted=true).
    //
    // Why fn_key_intercepted is necessary:
    //   On Globe Macs, the release sequence can be KEY_UP(63) → FLAGS_CHANGED(fn=false).
    //   KEY_UP resets previous_fn_state to false *before* FLAGS_CHANGED arrives, so both
    //   fn_pressed and prev_fn_state are false when FLAGS_CHANGED is processed, causing the
    //   old `fn_pressed || prev_fn_state` guard to fail and letting FLAGS_CHANGED pass through
    //   to the system — which re-arms the emoji picker.  fn_key_intercepted is set on Globe
    //   KEY_DOWN and cleared here once FLAGS_CHANGED(fn=false) is consumed, covering this gap.
    if callback_data.intercept_system && callback_data.intercept_fn_key {
        let fn_was_intercepted = callback_data.fn_key_intercepted.load(Ordering::SeqCst);
        if fn_pressed || prev_fn_state || fn_was_intercepted {
            // If this is the fn=false release FLAGS_CHANGED and we had an in-flight
            // interception, clear the flag so it doesn't latch indefinitely.
            if !fn_pressed && fn_was_intercepted {
                callback_data.fn_key_intercepted.store(false, Ordering::SeqCst);
            }
            return std::ptr::null_mut();
        }
    }

    event
}

// ── TIS FN Usage Type API ─────────────────────────────────────────────────
//
// TextInputSwitcher (macOS 16+) calls TISGetFnUsageType (HIToolbox) to obtain
// its isFnForEmoji value at startup and in response to TIS change notifications.
// System Preferences writes via TISUpdateFnUsageType, which both persists the
// value to the com.apple.HIToolbox preferences domain AND posts TIS change
// notifications — so TextInputSwitcher refreshes isFnForEmoji live, with no
// daemon restarts needed. Using `defaults write` + `killall` bypasses these
// notifications and therefore never updates the running TextInputSwitcher state.
//
// HIToolbox is a sub-framework of Carbon.framework; we load it via dlopen at
// runtime to avoid linker issues with the sub-framework path.
//
// AppleFnUsageType values:
//   0 = Do Nothing
//   1 = Change Input Source
//   2 = Show Emoji & Symbols  (default on Apple Silicon)
//   3 = Start Dictation

// dlopen / dlsym are in libSystem which is always linked on macOS.
extern "C" {
    fn dlopen(filename: *const i8, flags: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const i8) -> *mut c_void;
}

const RTLD_LAZY: i32 = 0x1;

// HIToolbox lives inside Carbon.framework on macOS.
const HITOOLBOX_PATH: &[u8] =
    b"/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox\0";

/// Read current Globe key FN usage type from HIToolbox TISGetFnUsageType.
/// Returns: 0=DoNothing, 1=ChangeInputSource, 2=ShowEmoji, 3=Dictation
pub fn tis_get_fn_usage_type() -> i32 {
    unsafe {
        let handle = dlopen(HITOOLBOX_PATH.as_ptr() as *const i8, RTLD_LAZY);
        if handle.is_null() {
            return 2; // fallback: emoji
        }
        let sym = dlsym(handle, b"TISGetFnUsageType\0".as_ptr() as *const i8);
        if sym.is_null() {
            return 2;
        }
        type TISGetFnUsageTypeFn = unsafe extern "C" fn() -> i32;
        let f: TISGetFnUsageTypeFn = std::mem::transmute(sym);
        f()
        // No dlclose: HIToolbox stays loaded (it's part of Carbon, always present)
    }
}

/// Set Globe key FN usage type via HIToolbox TISUpdateFnUsageType.
/// Writes the preference AND posts TIS change notifications so that
/// TextInputSwitcher refreshes isFnForEmoji live — no daemon restart needed.
pub fn tis_set_fn_usage_type(value: i32) {
    unsafe {
        let handle = dlopen(HITOOLBOX_PATH.as_ptr() as *const i8, RTLD_LAZY);
        if handle.is_null() {
            return;
        }
        let sym = dlsym(handle, b"TISUpdateFnUsageType\0".as_ptr() as *const i8);
        if sym.is_null() {
            return;
        }
        type TISUpdateFnUsageTypeFn = unsafe extern "C" fn(i32);
        let f: TISUpdateFnUsageTypeFn = std::mem::transmute(sym);
        f(value);
        // No dlclose: HIToolbox stays loaded (it's part of Carbon, always present)
    }
}
