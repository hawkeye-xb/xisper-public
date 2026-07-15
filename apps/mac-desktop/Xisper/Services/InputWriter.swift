/**
 * InputWriter
 *
 * Injects transcribed text into the focused application.
 * Strategy: clipboard paste (save → write → Cmd+V CGEvent → async restore).
 * Replaces writer.ts + clipboard.ts + @jitsi/robotjs dependency.
 *
 * Requires com.apple.security.accessibility entitlement.
 */

import AppKit
import CoreGraphics
import Foundation

// MARK: - Write result

struct WriteResult {
    let success:      Bool
    let charsWritten: Int
    let error:        String?
}

// MARK: - InputWriter

enum InputWriter {

    // MARK: - Public API

    /// Inject text into the focused app via clipboard paste.
    /// Saves and restores the clipboard contents asynchronously.
    @MainActor
    static func write(_ text: String) async -> WriteResult {
        guard !text.isEmpty else {
            return WriteResult(success: true, charsWritten: 0, error: nil)
        }

        let pb = NSPasteboard.general
        let shouldKeepInClipboard = ConfigStore.shared.copyToClipboard

        // 1. Snapshot current clipboard so we can restore it later (unless user wants to keep text in clipboard).
        let savedItems = shouldKeepInClipboard ? nil : pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        // 2. Write transcription text to clipboard.
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 3. Brief pause for clipboard to be ready (~30 ms).
        try? await Task.sleep(nanoseconds: 30_000_000)

        // 4. Check AX trust before posting CGEvents.
        guard AXIsProcessTrusted() else {
            // Restore clipboard since paste won't happen.
            if !shouldKeepInClipboard, let items = savedItems, !items.isEmpty {
                pb.clearContents()
                pb.writeObjects(items)
            }
            NotificationCenter.default.post(name: .navigateToPermissions, object: nil)
            return WriteResult(success: false, charsWritten: 0, error: "Accessibility access required")
        }

        // 5. Simulate Cmd+V in the frontmost app.
        simulatePaste()

        // 6. Allow paste to complete (~100 ms) then conditionally restore clipboard.
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                if !shouldKeepInClipboard {
                    pb.clearContents()
                    if let items = savedItems, !items.isEmpty {
                        pb.writeObjects(items)
                    }
                }
            }
        }

        return WriteResult(success: true, charsWritten: text.count, error: nil)
    }

    /// Write text to clipboard only (no paste). The user must paste manually.
    @MainActor
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Auto-Enter after paste (headphone trigger)

    /// Paste text then fire Enter after a short delay. Does NOT block MainActor.
    /// The paste itself happens synchronously via write(); Enter is dispatched asynchronously
    /// so commitResult() can return immediately without holding MainActor.
    @MainActor
    static func writeAndPressEnter(_ text: String) async -> WriteResult {
        let result = await write(text)
        guard result.success else { return result }

        // Fire Enter asynchronously — don't block commitResult on MainActor.
        // 300ms is enough for any app to complete the paste.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            simulateEnter()
        }
        return result
    }

    // MARK: - Private

    /// Post a Cmd+V CGEvent pair to the HID event tap.
    private static func simulatePaste() {
        // Virtual key 9 = 'v' on US layout (and all macOS keyboard layouts for Cmd+V)
        let src = CGEventSource(stateID: .hidSystemState)
        let kd  = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let ku  = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        kd?.flags = .maskCommand
        ku?.flags = .maskCommand
        kd?.post(tap: .cgAnnotatedSessionEventTap)
        ku?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Post a Return key CGEvent pair (virtual key 36) with no modifier flags.
    private static func simulateEnter() {
        let src = CGEventSource(stateID: .hidSystemState)
        let kd  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)   // 0x24 = 36 = Return
        let ku  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
        kd?.post(tap: .cgAnnotatedSessionEventTap)
        ku?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
