import AVFoundation
import CoreAudio
import Sparkle
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: NSLocalizedString("Settings", comment: ""))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
                    PreferencesCard()
                    ShortcutsCard()
                    AudioCard()
                    IntegrationCard()
                    AccountCard()
                }
                .padding(.vertical, DesignSpacing.sm)
                .padding(.horizontal, DesignSpacing.sm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.neutral1)
    }
}

// MARK: - Card container

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.neutral9)
                .padding(.bottom, 8)

            content()
        }
        .padding(DesignSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.neutral2)
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.md)
                .stroke(Color.neutral3, lineWidth: 1)
        )
    }
}

private struct CardDivider: View {
    var body: some View {
        Color.neutral3.frame(height: 1)
            .padding(.horizontal, -DesignSpacing.xxs)
            .padding(.horizontal, DesignSpacing.xxs)
    }
}

// MARK: - Shared row helpers

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.neutral9)
    }
}

struct SettingRow: View {
    let title: String
    let description: String?

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.neutral12)
            if let desc = description {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.neutral7)
            }
        }
    }
}

// MARK: - 1. Preferences (high-frequency)

private struct PreferencesCard: View {
    @AppStorage("AppleInterfaceStyle") private var interfaceStyle: String?
    private var config: ConfigStore { ConfigStore.shared }
    private var translateSettings: TranslateSettings { TranslateSettings.shared }

    private static let asrLanguages: [(id: String, label: String)] = [
        ("zh-CN", NSLocalizedString("Chinese (Mandarin)", comment: "")),
        ("en",    NSLocalizedString("English", comment: "")),
        ("ja",    NSLocalizedString("Japanese", comment: "")),
        ("ko",    NSLocalizedString("Korean", comment: "")),
        ("yue",   NSLocalizedString("Cantonese", comment: "")),
    ]

    private static let uiLanguages: [(id: String, label: String)] = [
        ("",        NSLocalizedString("System", comment: "")),
        ("en",      "English"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("ja",      "Japanese"),
    ]

    private var currentAppearance: Appearance {
        if let style = interfaceStyle, style == "Dark" { return .dark }
        else if interfaceStyle == nil { return .system }
        else { return .light }
    }

    var body: some View {
        SettingsCard(title: NSLocalizedString("Preferences", comment: "")) {
            // Appearance
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Appearance", comment: ""), description: NSLocalizedString("Light, Dark, or System", comment: ""))
                Spacer()
                Picker("", selection: Binding(
                    get: { currentAppearance },
                    set: { newValue in
                        switch newValue {
                        case .system:
                            interfaceStyle = nil
                            NSApp.appearance = nil
                        case .light:
                            interfaceStyle = "Light"
                            NSApp.appearance = NSAppearance(named: .aqua)
                        case .dark:
                            interfaceStyle = "Dark"
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                        }
                    }
                )) {
                    Text(NSLocalizedString("Dark", comment: "")).tag(Appearance.dark)
                    Text(NSLocalizedString("Light", comment: "")).tag(Appearance.light)
                    Text(NSLocalizedString("System", comment: "")).tag(Appearance.system)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            // UI Language
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Language", comment: ""), description: NSLocalizedString("App display language", comment: ""))
                Spacer()
                Picker("", selection: Binding(
                    get: { config.uiLanguage },
                    set: {
                        config.set(uiLanguage: $0)
                        // Recreate window content to reflect new language immediately
                        Task { @MainActor in
                            LanguageManager.shared.refreshUI()
                        }
                    }
                )) {
                    ForEach(Self.uiLanguages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            // Speech Language
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Speech Language", comment: ""), description: NSLocalizedString("Affects ASR recognition accuracy", comment: ""))
                Spacer()
                Picker("", selection: Binding(
                    get: { config.asrLanguage },
                    set: { config.set(asrLanguage: $0) }
                )) {
                    ForEach(Self.asrLanguages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            // Translation target
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Translation Target", comment: ""), description: NSLocalizedString("Translate into this language (FN+T)", comment: ""))
                Spacer()
                Picker("", selection: Binding(
                    get: { translateSettings.targetLanguage },
                    set: { translateSettings.set(targetLanguage: $0) }
                )) {
                    ForEach(TranslateSettings.languages) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            // Copy to Clipboard
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Copy to Clipboard", comment: ""), description: NSLocalizedString("Also save transcription to clipboard after paste", comment: ""))
                Spacer()
                Toggle("", isOn: config.copyToClipboardBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)

        }
    }

    private enum Appearance { case system, light, dark }
}

// MARK: - 2. Shortcuts (keyboard related)

private struct ShortcutsCard: View {
    @State private var editingActionId: String?
    @State private var heldKeys: Set<String> = []
    @State private var recordingKeys: [String] = []
    @State private var validationError: String?

    private var store: ShortcutStore { ShortcutStore.shared }
    private var config: ConfigStore { ConfigStore.shared }

    var body: some View {
        SettingsCard(title: NSLocalizedString("Shortcuts", comment: "")) {
            ForEach(Array(store.actions.enumerated()), id: \.element.id) { index, action in
                HStack(alignment: .center) {
                    SettingRow(action.name, description: action.description)
                    Spacer()

                    if editingActionId == action.id {
                        recordingView(for: action)
                    } else {
                        shortcutBadges(for: action.primaryShortcut)
                            .contentShape(Rectangle())
                            .onTapGesture { startEditing(action.id) }
                    }
                }
                .padding(.vertical, 8)

                if index < store.actions.count - 1 {
                    CardDivider()
                }
            }

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Intercept System Key", comment: ""), description: NSLocalizedString("Block FN from triggering emoji panel", comment: ""))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { config.interceptSystemKey },
                    set: {
                        config.set(interceptSystemKey: $0)
                        HotkeySystem.shared.reloadShortcuts()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Headphone Button Trigger", comment: ""), description: NSLocalizedString("Toggle recording with the Play button on wired or wireless headphones. Music apps won't receive this button press while enabled.", comment: ""))
                Spacer()
                Toggle("", isOn: config.headphoneButtonTriggerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Auto-Enter After Paste", comment: ""), description: NSLocalizedString("When pasting text triggered by a headphone button, automatically press Enter to send the message. Only applies to headphone button trigger, not FN key shortcuts.", comment: ""))
                Spacer()
                Toggle("", isOn: config.autoEnterBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)
        }
        .onDisappear { cancelEditing() }
    }

    @ViewBuilder
    private func shortcutBadges(for shortcut: String) -> some View {
        let keys = shortcutDisplayKeys(shortcut)
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.neutral7)
                }
                Text(key)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.neutral12)
                    .padding(.horizontal, DesignSpacing.xxxs)
                    .padding(.vertical, DesignSpacing.xxxxs)
                    .background(Color.neutral1)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm)
                            .stroke(Color.neutral3, lineWidth: 1)
                    )
                    .frame(height: 28)
            }
        }
    }

    @ViewBuilder
    private func recordingView(for action: AppShortcutAction) -> some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("Press keys…", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(Color.neutral7)

            if !recordingKeys.isEmpty {
                Text(recordingKeys.joined(separator: " + "))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary8)
            }

            Button(NSLocalizedString("Cancel", comment: "")) { cancelEditing() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.neutral7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary1)
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .stroke(Color.primary6, lineWidth: 1)
        )
    }

    private func startEditing(_ actionId: String) {
        editingActionId = actionId
        heldKeys = []
        recordingKeys = []
        validationError = nil
    }

    private func cancelEditing() {
        editingActionId = nil
        heldKeys = []
        recordingKeys = []
        validationError = nil
    }

    private func shortcutDisplayKeys(_ shortcut: String) -> [String] {
        shortcut.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 3. Audio (device & behavior)

private struct AudioCard: View {
    private var config: ConfigStore { ConfigStore.shared }
    @State private var audioTestState: AudioTestState = .idle

    private enum AudioTestState {
        case idle, recording, playing
    }

    var body: some View {
        SettingsCard(title: NSLocalizedString("Audio", comment: "")) {
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Input Device", comment: ""), description: NSLocalizedString("Microphone used for recording", comment: ""))
                Spacer()
                Text(currentInputDeviceName())
                    .font(.system(size: 13))
                    .foregroundStyle(Color.neutral9)
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Test Microphone", comment: ""), description: NSLocalizedString("Record a short clip and play it back", comment: ""))
                Spacer()
                Button(audioTestButtonTitle) {
                    handleAudioTest()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.primary8)
                .disabled(audioTestState == .playing)
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Mute Other Audio", comment: ""), description: NSLocalizedString("Lower system volume while recording", comment: ""))
                Spacer()
                Toggle("", isOn: config.muteSystemAudioBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)
        }
    }

    private var audioTestButtonTitle: String {
        switch audioTestState {
        case .idle:      return NSLocalizedString("Start Test", comment: "")
        case .recording: return NSLocalizedString("Stop & Play", comment: "")
        case .playing:   return NSLocalizedString("Playing…", comment: "")
        }
    }

    private func currentInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return NSLocalizedString("Unknown", comment: "") }

        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        guard nameStatus == noErr else { return NSLocalizedString("Unknown", comment: "") }
        return name as String
    }

    private func handleAudioTest() {
        switch audioTestState {
        case .idle:
            audioTestState = .recording
            Task {
                await AudioTestManager.shared.startRecording()
            }
        case .recording:
            audioTestState = .playing
            Task {
                await AudioTestManager.shared.stopAndPlay()
                await MainActor.run { audioTestState = .idle }
            }
        case .playing:
            break
        }
    }
}

// MARK: - 4. Integration (webhook & advanced)

private struct IntegrationCard: View {
    private var config: ConfigStore { ConfigStore.shared }
    @State private var webhookURL: String = ""
    @State private var showSavedFeedback = false

    var body: some View {
        SettingsCard(title: NSLocalizedString("Integration", comment: "")) {
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Post-processing", comment: ""), description: NSLocalizedString("Use LLM to clean up transcription text", comment: ""))
                Spacer()
                Toggle("", isOn: config.postProcessingEnabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)

            CardDivider()

            VStack(alignment: .leading, spacing: 8) {
                SettingRow(NSLocalizedString("Webhook URL", comment: ""), description: NSLocalizedString("Send transcription results to this URL (e.g. n8n, Zapier)", comment: ""))
                HStack(spacing: 8) {
                    TextField("https://…", text: $webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                    Button(showSavedFeedback ? NSLocalizedString("Saved ✓", comment: "") : NSLocalizedString("Save", comment: "")) {
                        config.set(webhookURL: webhookURL)
                        withAnimation { showSavedFeedback = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showSavedFeedback = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primary8)
                    .disabled(webhookURL == config.webhookURL)
                }
            }
            .padding(.vertical, 8)
            .onAppear { webhookURL = config.webhookURL }
        }
    }
}

// MARK: - 5. Account (identity & updates)

private struct AccountCard: View {
    private var auth: AuthManager { AuthManager.shared }
    private var usage: UsageManager { UsageManager.shared }
    @State private var isCheckingUpdate = false

    var body: some View {
        SettingsCard(title: NSLocalizedString("Account", comment: "")) {
            HStack(alignment: .center) {
                SettingRow(
                    auth.userEmail ?? NSLocalizedString("Not signed in", comment: ""),
                    description: auth.isLoggedIn ? nil : NSLocalizedString("Sign in to sync your data", comment: "")
                )
                Spacer()
                if auth.isLoggedIn {
                    Button(NSLocalizedString("Sign Out", comment: "")) {
                        auth.logout()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(NSLocalizedString("Sign In", comment: "")) {
                        auth.startLoginFlow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primary8)
                }
            }
            .padding(.vertical, 8)

            if auth.isLoggedIn {
                CardDivider()

                // Usage summary
                HStack(alignment: .center) {
                    SettingRow(
                        NSLocalizedString("Plan", comment: ""),
                        description: usage.isUnlimitedTier ? NSLocalizedString("Unlimited usage", comment: "") : nil
                    )
                    Spacer()
                    Text(planDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(usage.isUnlimitedTier ? Color.success8 : Color.neutral12)
                }
                .padding(.vertical, 8)

                if usage.showsFiniteCharacterQuotaBar {
                    CardDivider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(NSLocalizedString("Characters Used", comment: ""))
                                .font(.system(size: 13))
                                .foregroundStyle(Color.neutral9)
                            Spacer()
                            Text("\(usage.asrCharacters.used) / \(usage.asrCharacters.limit)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.neutral12)
                        }
                        ProgressView(value: usage.asrCharacters.fraction)
                            .tint(quotaBarColor)
                        Text(NSLocalizedString("Resets", comment: "") + " " + usage.resetLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.neutral7)
                    }
                    .padding(.vertical, 8)
                }
            }

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Version", comment: ""), description: Bundle.main.appVersionString)
                Spacer()
                Button(isCheckingUpdate ? NSLocalizedString("Checking…", comment: "") : NSLocalizedString("Check for Updates", comment: "")) {
                    isCheckingUpdate = true
                    SUStandardUpdaterController().checkForUpdates(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCheckingUpdate = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingUpdate)
            }
            .padding(.vertical, 8)
        }
    }

    private var planDisplayName: String {
        switch usage.tier.lowercased() {
        case "pro":        return "Pro"
        case "unlimited":  return "Unlimited"
        case "enterprise": return "Enterprise"
        default:           return "Free"
        }
    }

    private var quotaBarColor: Color {
        let f = usage.asrCharacters.fraction
        if f >= 0.9 { return Color.danger8 }
        if f >= 0.7 { return Color.warning8 }
        return Color.primary8
    }
}

// MARK: - Bundle version helper

extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
