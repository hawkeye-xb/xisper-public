//! Platform-specific implementations

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(target_os = "macos")]
pub use macos::MacOSEventTap;

// Stub for non-macOS platforms (compile-time check)
#[cfg(not(target_os = "macos"))]
compile_error!("fn-key-monitor only supports macOS");

