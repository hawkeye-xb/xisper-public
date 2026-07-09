import Foundation
import ObjectiveC

// MARK: - LanguageManager

/// Manages in-app language override via Bundle swizzling.
///
/// Call `LanguageManager.applySwizzle()` once, as early as possible (before any
/// `NSLocalizedString` call), to replace `Bundle.main`'s class with a subclass
/// that redirects localized-string lookups to the user-selected `.lproj` bundle.
final class LanguageManager {

    static let shared = LanguageManager()

    /// The override bundle for the selected language.
    /// - `nil` means "follow system".
    /// - For "en" (source language with no en.lproj), set `forceSourceLanguage` instead.
    private(set) var overrideBundle: Bundle?

    /// When `true`, `localizedString` returns the key itself (= English source text).
    private(set) var forceSourceLanguage = false

    // MARK: - Init

    private init() {
        let stored = Self.readStoredLanguage()
        if !stored.isEmpty {
            applyLanguage(stored)
        }
    }

    // MARK: - Public

    /// Update the override language. Pass `""` for system default.
    func setLanguage(_ code: String) {
        applyLanguage(code)
    }

    /// Recreate the main window's content to reflect the new language.
    @MainActor
    func refreshUI() {
        guard let delegate = AppDelegate.shared,
              let window = delegate.mainWindow else { return }

        // Dynamically import SwiftUI to avoid top-level dependency
        let hosting = _makeHostingController()
        window.contentViewController = hosting
    }

    // MARK: - Swizzle entry point

    /// Replace Bundle.main's class once. Safe to call multiple times (no-op after first).
    static func applySwizzle() {
        _ = swizzleOnce
    }

    private static let swizzleOnce: Void = {
        object_setClass(Bundle.main, LanguageBundle.self)
    }()

    // MARK: - Private

    private func applyLanguage(_ code: String) {
        if code.isEmpty {
            // System default
            overrideBundle = nil
            forceSourceLanguage = false
        } else if code == "en" {
            // English is the source/development language — no en.lproj exists.
            // Return the key itself which IS the English text.
            overrideBundle = nil
            forceSourceLanguage = true
        } else if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) {
            overrideBundle = bundle
            forceSourceLanguage = false
        } else {
            // Fallback: requested lproj not found → system default
            overrideBundle = nil
            forceSourceLanguage = false
        }
    }

    private static func readStoredLanguage() -> String {
        // Read from the same suite ConfigStore uses
        let defaults: UserDefaults = {
            if let suite = UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) {
                return suite
            }
            return .standard
        }()
        return defaults.string(forKey: "xisper.uiLanguage") ?? ""
    }
}

// MARK: - Bundle subclass (swizzled onto Bundle.main)

private class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let mgr = LanguageManager.shared

        // Force English: return the key itself (source language)
        if mgr.forceSourceLanguage {
            return key
        }

        // Override to specific language bundle
        if let bundle = mgr.overrideBundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }

        // System default
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// MARK: - Window content factory (avoids importing SwiftUI in this file's top level)

import SwiftUI

@MainActor
private func _makeHostingController() -> NSHostingController<some View> {
    NSHostingController(
        rootView: ContentView()
            .modelContainer(XisperApp.modelContainer)
    )
}
