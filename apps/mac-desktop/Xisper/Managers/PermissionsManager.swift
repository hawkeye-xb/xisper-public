import AppKit
import AVFAudio
import AVFoundation
import ApplicationServices

@Observable
final class PermissionsManager {

    static let shared = PermissionsManager()

    private(set) var accessibilityGranted = false
    private(set) var microphoneGranted = false

    private init() { refresh() }

    // MARK: - Public

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - Accessibility

    /// Request accessibility permission - show system prompt first, then open Settings if needed.
    func requestAccessibility() {
        // Try system prompt first - this shows the native macOS Alert
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let granted = AXIsProcessTrustedWithOptions(opts as CFDictionary)

        if granted {
            refresh()
        } else {
            // System prompt didn't show (already denied before) - open System Settings
            openAccessibilitySettings()
            startPollingForAccessibility()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var accessibilityPollingTimer: Timer?

    private func startPollingForAccessibility() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
            if self?.accessibilityGranted == true {
                self?.accessibilityPollingTimer?.invalidate()
                self?.accessibilityPollingTimer = nil
            }
        }
    }

    // MARK: - Microphone

    /// Request microphone permission - always try requestRecordPermission first.
    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { granted in
            print("🎤 requestRecordPermission result:", granted)
            DispatchQueue.main.async {
                if granted {
                    self.refresh()
                } else {
                    self.openMicrophoneSettings()
                    self.startPollingForMicrophone()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private var microphonePollingTimer: Timer?

    private func startPollingForMicrophone() {
        microphonePollingTimer?.invalidate()
        microphonePollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
            if self?.microphoneGranted == true {
                self?.microphonePollingTimer?.invalidate()
                self?.microphonePollingTimer = nil
            }
        }
    }

    var allGranted: Bool { accessibilityGranted && microphoneGranted }
}
