//! Core module for FN key monitoring
//!
//! This module contains the pure Rust implementation that can be used
//! both as a NAPI module (for Electron) and as a regular Rust library (for Tauri).

mod detector;
mod event;
mod monitor;

pub use detector::EventDetector;
pub use event::{FnKeyConfig, FnKeyEvent, FnKeyEventType};
pub use monitor::FnKeyMonitor;

