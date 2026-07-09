//! Event detector for single press, double tap, and long press detection

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use parking_lot::Mutex;

use super::event::{FnKeyConfig, FnKeyEvent, FnKeyEventType};

/// Callback type for event detection
pub type EventCallback = Box<dyn Fn(FnKeyEvent) + Send + Sync + 'static>;

/// Event detector that handles single press, double tap, and long press detection
pub struct EventDetector {
    config: FnKeyConfig,
    callback: Arc<Mutex<Option<EventCallback>>>,

    // State tracking
    is_pressed: AtomicBool,
    last_press_time: AtomicU64,
    long_press_triggered: AtomicBool,
    long_press_cancel: Arc<AtomicBool>,
}

impl EventDetector {
    /// Create a new event detector with the given configuration
    pub fn new(config: FnKeyConfig) -> Self {
        Self {
            config,
            callback: Arc::new(Mutex::new(None)),
            is_pressed: AtomicBool::new(false),
            last_press_time: AtomicU64::new(0),
            long_press_triggered: AtomicBool::new(false),
            long_press_cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Set the callback for events
    pub fn set_callback<F>(&self, callback: F)
    where
        F: Fn(FnKeyEvent) + Send + Sync + 'static,
    {
        let mut cb = self.callback.lock();
        *cb = Some(Box::new(callback));
    }

    /// Clear the callback
    pub fn clear_callback(&self) {
        let mut cb = self.callback.lock();
        *cb = None;
    }

    /// Handle FN key press event from the platform layer
    pub fn on_fn_pressed(&self) {
        let now = Self::current_time_ms();
        let last_press = self.last_press_time.load(Ordering::SeqCst);

        // Check for double tap
        let is_double_tap =
            last_press > 0 && (now - last_press) <= self.config.double_tap_interval;

        // Update state
        self.is_pressed.store(true, Ordering::SeqCst);
        self.last_press_time.store(now, Ordering::SeqCst);
        self.long_press_triggered.store(false, Ordering::SeqCst);
        self.long_press_cancel.store(false, Ordering::SeqCst);

        // Emit press event
        self.emit_event(FnKeyEvent::with_timestamp(FnKeyEventType::Press, now));

        // Emit double tap event if detected
        if is_double_tap {
            self.emit_event(FnKeyEvent::with_timestamp(FnKeyEventType::DoubleTap, now));
            // Reset last press time to prevent triple-tap being detected as double-tap
            self.last_press_time.store(0, Ordering::SeqCst);
        }

        // Start long press timer
        self.start_long_press_timer(now);
    }

    /// Handle FN key release event from the platform layer
    pub fn on_fn_released(&self) {
        let now = Self::current_time_ms();

        // Cancel long press timer
        self.long_press_cancel.store(true, Ordering::SeqCst);

        let was_pressed = self.is_pressed.swap(false, Ordering::SeqCst);
        if !was_pressed {
            return;
        }

        // Check if long press was triggered
        let was_long_press = self.long_press_triggered.load(Ordering::SeqCst);

        if was_long_press {
            // Emit long press end event
            self.emit_event(FnKeyEvent::with_timestamp(
                FnKeyEventType::LongPressEnd,
                now,
            ));
        }

        // Always emit release event
        self.emit_event(FnKeyEvent::with_timestamp(FnKeyEventType::Release, now));
    }

    /// Reset the detector state
    pub fn reset(&self) {
        self.is_pressed.store(false, Ordering::SeqCst);
        self.last_press_time.store(0, Ordering::SeqCst);
        self.long_press_triggered.store(false, Ordering::SeqCst);
        self.long_press_cancel.store(true, Ordering::SeqCst);
    }

    /// Start the long press detection timer
    fn start_long_press_timer(&self, press_time: u64) {
        let duration = self.config.long_press_duration;
        let cancel_flag = Arc::clone(&self.long_press_cancel);
        let is_pressed = &self.is_pressed as *const AtomicBool;
        let long_press_triggered = &self.long_press_triggered as *const AtomicBool;
        let callback = Arc::clone(&self.callback);

        // SAFETY: We ensure the detector lives longer than the timer thread
        // by cancelling the timer in reset() and on_fn_released()
        let is_pressed = unsafe { &*is_pressed };
        let long_press_triggered = unsafe { &*long_press_triggered };

        thread::spawn(move || {
            thread::sleep(Duration::from_millis(duration));

            // Check if cancelled or released
            if cancel_flag.load(Ordering::SeqCst) {
                return;
            }

            // Check if still pressed
            if !is_pressed.load(Ordering::SeqCst) {
                return;
            }

            // Mark long press as triggered
            long_press_triggered.store(true, Ordering::SeqCst);

            // Emit long press event
            let event = FnKeyEvent::with_timestamp(
                FnKeyEventType::LongPress,
                press_time + duration,
            );

            if let Some(ref cb) = *callback.lock() {
                cb(event);
            }
        });
    }

    /// Emit an event to the callback
    fn emit_event(&self, event: FnKeyEvent) {
        if let Some(ref cb) = *self.callback.lock() {
            cb(event);
        }
    }

    /// Get current time in milliseconds
    fn current_time_ms() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
}

impl Drop for EventDetector {
    fn drop(&mut self) {
        self.reset();
    }
}

