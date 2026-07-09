import Foundation
import Security
import SwiftUI

// MARK: - ConfigStore

/// Centralised configuration store.
///
/// Non-sensitive preferences are persisted in `UserDefaults`.
/// ASR authentication is handled by `AuthManager` (token file under Application Support) — no manual credentials needed.
@Observable
final class ConfigStore {

    static let shared = ConfigStore()

    // MARK: - UserDefaults-backed preferences

    private(set) var selectedMicrophoneId: String?     = nil
    private(set) var enableSoundEffects: Bool          = false
    private(set) var muteSystemDuringRecording: Bool   = false
    // ASR language
    private(set) var asrLanguage: String               = "zh-CN"

    // Recording behaviour
    private(set) var recordingMode: RecordingMode      = .pressToggle
    private(set) var interceptSystemKey: Bool          = true
    private(set) var copyToClipboard: Bool             = true
    private(set) var enableHeadphoneButtonTrigger: Bool   = false

    // UI language override (empty = system)
    private(set) var uiLanguage: String               = ""

    // MARK: - Init

    private init() { load() }

    // MARK: - Setters

    func set(selectedMicrophoneId v: String?) {
        selectedMicrophoneId = v; defaults.set(v, forKey: Keys.selectedMic)
    }
    func set(enableSoundEffects v: Bool) {
        enableSoundEffects = v; defaults.set(v, forKey: Keys.soundEffects)
    }
    func set(muteSystemDuringRecording v: Bool) {
        muteSystemDuringRecording = v; defaults.set(v, forKey: Keys.muteSystem)
    }
    func set(asrLanguage v: String) {
        asrLanguage = v; defaults.set(v, forKey: Keys.asrLanguage)
    }
    func set(recordingMode v: RecordingMode) {
        recordingMode = v; defaults.set(v.rawValue, forKey: Keys.recordingMode)
    }
    func set(interceptSystemKey v: Bool) {
        interceptSystemKey = v; defaults.set(v, forKey: Keys.interceptKey)
    }
    func set(copyToClipboard v: Bool) {
        copyToClipboard = v; defaults.set(v, forKey: Keys.copyToClipboard)
    }
    func set(enableHeadphoneButtonTrigger v: Bool) {
        enableHeadphoneButtonTrigger = v; defaults.set(v, forKey: Keys.headphoneButtonTrigger)
    }
    func set(uiLanguage v: String) {
        uiLanguage = v; defaults.set(v, forKey: Keys.uiLanguage)
        LanguageManager.shared.setLanguage(v)
    }

    // MARK: - Private

    private let defaults: UserDefaults = {
        // Use environment-specific suite for beta/prod separation
        if let suite = UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) {
            return suite
        }
        return UserDefaults.standard
    }()

    private enum Keys {
        static let selectedMic      = "xisper.selectedMicrophoneId"
        static let soundEffects     = "xisper.enableSoundEffects"
        static let muteSystem       = "xisper.muteSystemDuringRecording"
        static let asrLanguage      = "xisper.asrLanguage"
        static let recordingMode    = "xisper.recordingMode"
        static let interceptKey     = "xisper.interceptSystemKey"
        static let copyToClipboard  = "xisper.copyToClipboard"
        static let headphoneButtonTrigger = "xisper.enableHeadphoneButtonTrigger"
        static let uiLanguage       = "xisper.uiLanguage"
    }

    private func load() {
        selectedMicrophoneId      = defaults.string(forKey: Keys.selectedMic)
        enableSoundEffects        = defaults.object(forKey: Keys.soundEffects) as? Bool ?? true
        muteSystemDuringRecording = defaults.object(forKey: Keys.muteSystem)   as? Bool ?? false
        asrLanguage               = defaults.string(forKey: Keys.asrLanguage) ?? "zh-CN"
        recordingMode             = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .pressToggle
        interceptSystemKey        = defaults.object(forKey: Keys.interceptKey) as? Bool ?? true
        copyToClipboard           = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        enableHeadphoneButtonTrigger = defaults.object(forKey: Keys.headphoneButtonTrigger) as? Bool ?? false
        uiLanguage                = defaults.string(forKey: Keys.uiLanguage) ?? ""
    }
}

// MARK: - Convenient Bindings

extension ConfigStore {

    var soundEffectsBinding: Binding<Bool> {
        Binding(get: { self.enableSoundEffects },
                set: { self.set(enableSoundEffects: $0) })
    }
    var muteSystemBinding: Binding<Bool> {
        Binding(get: { self.muteSystemDuringRecording },
                set: { self.set(muteSystemDuringRecording: $0) })
    }
    var copyToClipboardBinding: Binding<Bool> {
        Binding(get: { self.copyToClipboard },
                set: { self.set(copyToClipboard: $0) })
    }
    var headphoneButtonTriggerBinding: Binding<Bool> {
        Binding(get: { self.enableHeadphoneButtonTrigger },
                set: { self.set(enableHeadphoneButtonTrigger: $0) })
    }
}
