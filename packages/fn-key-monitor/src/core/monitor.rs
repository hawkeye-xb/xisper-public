//! FN key monitor - the main interface for the core library

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;

use super::detector::EventDetector;
use super::event::{FnKeyConfig, FnKeyEvent};
use crate::platform::MacOSEventTap;

/// FN key monitor that provides a high-level interface for monitoring FN key events
pub struct FnKeyMonitor {
    config: FnKeyConfig,
    detector: Arc<EventDetector>,
    event_tap: Arc<Mutex<Option<MacOSEventTap>>>,
    is_running: AtomicBool,
}

impl FnKeyMonitor {
    /// Create a new FN key monitor with the given configuration
    pub fn new(config: FnKeyConfig) -> Self {
        let detector = Arc::new(EventDetector::new(config.clone()));

        Self {
            config,
            detector,
            event_tap: Arc::new(Mutex::new(None)),
            is_running: AtomicBool::new(false),
        }
    }

    /// Start monitoring FN key events
    ///
    /// # Arguments
    /// * `callback` - Function to call when an FN key event occurs
    ///
    /// # Returns
    /// * `Ok(())` if started successfully
    /// * `Err(String)` if failed to start
    pub fn start<F>(&self, callback: F) -> Result<(), String>
    where
        F: Fn(FnKeyEvent) + Send + Sync + 'static,
    {
        if self.is_running.load(Ordering::SeqCst) {
            return Err("Monitor is already running".to_string());
        }

        // Set up the callback on the detector
        self.detector.set_callback(callback);

        // Create the event tap (pass whitelist so we only block configured shortcuts)
        let detector = Arc::clone(&self.detector);
        let intercept_system = self.config.intercept_system;
        let intercept_fn_key = self.config.intercept_fn_key;
        let intercept_key_codes: std::collections::HashSet<i64> = self
            .config
            .intercept_key_codes_when_fn_down
            .iter()
            .copied()
            .collect();
        let intercept_shortcuts = self.config.intercept_shortcuts.clone();

        let event_tap = MacOSEventTap::new(
            move |pressed| {
                if pressed {
                    detector.on_fn_pressed();
                } else {
                    detector.on_fn_released();
                }
            },
            intercept_system,
            intercept_fn_key,
            intercept_key_codes,
            intercept_shortcuts,
        )
        .map_err(|e| format!("Failed to create event tap: {}", e))?;

        // Start the event tap
        event_tap
            .start()
            .map_err(|e| format!("Failed to start event tap: {}", e))?;

        // Store the event tap
        {
            let mut tap = self.event_tap.lock();
            *tap = Some(event_tap);
        }

        self.is_running.store(true, Ordering::SeqCst);

        Ok(())
    }

    /// Stop monitoring FN key events
    pub fn stop(&self) {
        if !self.is_running.load(Ordering::SeqCst) {
            return;
        }

        // Stop and remove the event tap
        {
            let mut tap = self.event_tap.lock();
            if let Some(event_tap) = tap.take() {
                event_tap.stop();
            }
        }

        // Reset the detector
        self.detector.reset();
        self.detector.clear_callback();

        self.is_running.store(false, Ordering::SeqCst);
    }

    /// Check if the monitor is currently running
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::SeqCst)
    }
}

impl Drop for FnKeyMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}

