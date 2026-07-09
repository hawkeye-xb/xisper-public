//! FN key event types and configuration

use std::time::{SystemTime, UNIX_EPOCH};

/// FN key event types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FnKeyEventType {
    /// FN key pressed down
    Press,
    /// FN key released
    Release,
    /// Double tap detected (two quick presses)
    DoubleTap,
    /// Long press started (held for threshold duration)
    LongPress,
    /// Long press ended (released after long press)
    LongPressEnd,
}

impl FnKeyEventType {
    /// Convert to string representation for JavaScript
    pub fn as_str(&self) -> &'static str {
        match self {
            FnKeyEventType::Press => "press",
            FnKeyEventType::Release => "release",
            FnKeyEventType::DoubleTap => "doubleTap",
            FnKeyEventType::LongPress => "longPress",
            FnKeyEventType::LongPressEnd => "longPressEnd",
        }
    }
}

/// FN key event with timestamp
#[derive(Debug, Clone)]
pub struct FnKeyEvent {
    /// Event type
    pub event_type: FnKeyEventType,
    /// Timestamp in milliseconds since epoch
    pub timestamp: u64,
}

impl FnKeyEvent {
    /// Create a new event with current timestamp
    pub fn new(event_type: FnKeyEventType) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);

        Self {
            event_type,
            timestamp,
        }
    }

    /// Create a new event with specific timestamp
    pub fn with_timestamp(event_type: FnKeyEventType, timestamp: u64) -> Self {
        Self {
            event_type,
            timestamp,
        }
    }
}

/// Configuration for FN key monitor
#[derive(Debug, Clone)]
pub struct FnKeyConfig {
    /// When true, enable intercept; only events matching intercept_fn_key / intercept_key_codes are blocked.
    pub intercept_system: bool,
    /// When intercept on: block the FN key itself (keycode 63 and flags-changed). Only if user configured "FN" shortcut.
    pub intercept_fn_key: bool,
    /// When intercept on: consume entire event for these keycodes when FN is down (user-configured FN+key shortcuts).
    pub intercept_key_codes_when_fn_down: Vec<i64>,
    /// Non-FN shortcuts to intercept: (CGEvent modifier_mask, Carbon keycode) pairs.
    pub intercept_shortcuts: Vec<(u64, i64)>,
    /// Double tap detection interval in milliseconds
    pub double_tap_interval: u64,
    /// Long press detection threshold in milliseconds
    pub long_press_duration: u64,
}

impl Default for FnKeyConfig {
    fn default() -> Self {
        Self {
            intercept_system: false,
            intercept_fn_key: false,
            intercept_key_codes_when_fn_down: Vec::new(),
            intercept_shortcuts: Vec::new(),
            double_tap_interval: 300,
            long_press_duration: 500,
        }
    }
}

