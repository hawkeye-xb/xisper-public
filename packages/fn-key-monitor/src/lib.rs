//! FN Key Monitor for macOS
//!
//! This crate provides a native Node.js module for monitoring FN key events on macOS.
//! It uses CGEventTap to detect FN key press/release events and supports:
//!
//! - Single press/release detection
//! - Double tap detection
//! - Long press detection
//! - Optional system event interception
//!
//! # Usage (Node.js/Electron)
//!
//! ```javascript
//! const { startMonitor, stopMonitor, isMonitorRunning } = require('@xisper/fn-key-monitor');
//!
//! startMonitor(
//!   { interceptSystem: true, longPressDuration: 500 },
//!   (event) => {
//!     console.log('FN key event:', event.type, event.timestamp);
//!   }
//! );
//! ```
//!
//! # Usage (Rust/Tauri)
//!
//! ```rust,ignore
//! use fn_key_monitor::core::{FnKeyConfig, FnKeyMonitor};
//!
//! let config = FnKeyConfig::default();
//! let monitor = FnKeyMonitor::new(config);
//!
//! monitor.start(|event| {
//!     println!("FN key event: {:?}", event.event_type);
//! }).expect("Failed to start monitor");
//! ```

#[macro_use]
extern crate napi_derive;

pub mod core;
pub mod platform;

use std::sync::Arc;

use napi::{
    bindgen_prelude::*,
    threadsafe_function::{ErrorStrategy, ThreadsafeFunction, ThreadsafeFunctionCallMode},
};
use parking_lot::Mutex;

use crate::core::{FnKeyConfig, FnKeyEvent, FnKeyMonitor};

/// Global monitor instance
static MONITOR: Mutex<Option<Arc<FnKeyMonitor>>> = Mutex::new(None);

/// JavaScript config object
#[napi(object)]
pub struct JsInterceptShortcut {
    pub modifier_mask: i64,
    pub keycode: i64,
}

#[napi(object)]
pub struct JsFnKeyConfig {
    /// Whether to intercept system behavior (only configured shortcuts are blocked)
    pub intercept_system: Option<bool>,
    /// When intercept on: block the FN key itself (user has "FN" shortcut)
    pub intercept_fn_key: Option<bool>,
    /// When intercept on: consume FN+key events entirely for these keycodes (FN+key shortcuts)
    pub intercept_key_codes_when_fn_down: Option<Vec<i64>>,
    /// Non-FN shortcuts to intercept: (modifier_mask, keycode) pairs
    pub intercept_shortcuts: Option<Vec<JsInterceptShortcut>>,
    /// Double tap detection interval in milliseconds
    pub double_tap_interval: Option<u32>,
    /// Long press detection threshold in milliseconds
    pub long_press_duration: Option<u32>,
}

impl From<JsFnKeyConfig> for FnKeyConfig {
    fn from(config: JsFnKeyConfig) -> Self {
        FnKeyConfig {
            intercept_system: config.intercept_system.unwrap_or(false),
            intercept_fn_key: config.intercept_fn_key.unwrap_or(false),
            intercept_key_codes_when_fn_down: config
                .intercept_key_codes_when_fn_down
                .unwrap_or_default(),
            intercept_shortcuts: config
                .intercept_shortcuts
                .unwrap_or_default()
                .into_iter()
                .map(|s| (s.modifier_mask as u64, s.keycode))
                .collect(),
            double_tap_interval: config.double_tap_interval.unwrap_or(300) as u64,
            long_press_duration: config.long_press_duration.unwrap_or(500) as u64,
        }
    }
}

/// Start monitoring FN key events
///
/// @param config - Configuration options
/// @param callback - Callback function to receive events
/// @throws Error if monitor is already running or failed to start
#[napi]
pub fn start_monitor(
    config: JsFnKeyConfig,
    #[napi(ts_arg_type = "(event: { type: string; timestamp: number }) => void")]
    callback: JsFunction,
) -> Result<()> {
    let mut monitor_lock = MONITOR.lock();

    if monitor_lock.is_some() {
        return Err(Error::new(
            Status::GenericFailure,
            "Monitor is already running. Call stopMonitor() first.",
        ));
    }

    // Create threadsafe function for the callback
    let tsfn: ThreadsafeFunction<FnKeyEvent, ErrorStrategy::Fatal> = callback
        .create_threadsafe_function(0, |ctx| {
            let event: FnKeyEvent = ctx.value;
            let mut obj = ctx.env.create_object()?;

            obj.set_named_property("type", event.event_type.as_str())?;
            obj.set_named_property("timestamp", event.timestamp as f64)?;

            Ok(vec![obj])
        })?;

    // Create the monitor
    let rust_config = FnKeyConfig::from(config);
    let monitor = Arc::new(FnKeyMonitor::new(rust_config));

    // Start the monitor with the callback
    let tsfn: Arc<ThreadsafeFunction<FnKeyEvent, ErrorStrategy::Fatal>> = Arc::new(tsfn);
    let tsfn_clone = Arc::clone(&tsfn);

    monitor
        .start(move |event| {
            tsfn_clone.call(event, ThreadsafeFunctionCallMode::NonBlocking);
        })
        .map_err(|e| Error::new(Status::GenericFailure, e))?;

    *monitor_lock = Some(monitor);

    Ok(())
}

/// Stop monitoring FN key events
#[napi]
pub fn stop_monitor() {
    let mut monitor_lock = MONITOR.lock();

    if let Some(monitor) = monitor_lock.take() {
        monitor.stop();
    }
}

/// Check if the monitor is currently running
///
/// @returns true if running, false otherwise
#[napi]
pub fn is_monitor_running() -> bool {
    let monitor_lock = MONITOR.lock();
    monitor_lock
        .as_ref()
        .map(|m| m.is_running())
        .unwrap_or(false)
}

/// Read the current Globe key FN usage type via HIToolbox TISGetFnUsageType.
///
/// Return values: 0 = Do Nothing, 1 = Change Input Source,
///                2 = Show Emoji & Symbols, 3 = Start Dictation
///
/// This is the same value TextInputSwitcher reads to set isFnForEmoji.
#[napi]
pub fn get_fn_usage_type() -> i32 {
    #[cfg(target_os = "macos")]
    {
        platform::macos::tis_get_fn_usage_type()
    }
    #[cfg(not(target_os = "macos"))]
    {
        2 // Default: emoji (safe fallback on non-macOS)
    }
}

/// Set the Globe key FN usage type via HIToolbox TISUpdateFnUsageType.
///
/// This is the same API System Preferences uses. It writes the preference
/// AND posts TIS change notifications so that TextInputSwitcher refreshes
/// its live isFnForEmoji state — no daemon restarts needed.
///
/// @param value 0 = Do Nothing, 1 = Change Input Source,
///              2 = Show Emoji & Symbols, 3 = Start Dictation
#[napi]
pub fn set_fn_usage_type(value: i32) {
    #[cfg(target_os = "macos")]
    {
        platform::macos::tis_set_fn_usage_type(value);
    }
}

