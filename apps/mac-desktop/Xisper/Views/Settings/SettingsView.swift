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
        ("zh-Hans", "简体中文"),
        ("ja",      "日本語"),
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
    private func recordingView(for action: ShortcutAction) -> some View {
        HStack(spacing: 8) {
            Group {
                if !recordingKeys.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(recordingKeys.enumerated()), id: \.offset) { index, key in
                            if index > 0 {
                                Text("+")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.neutral7)
                            }
                            Text(ShortcutKey.formatKeySymbol(key))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.neutral12)
                        }
                    }
                } else {
                    Text(NSLocalizedString("Press keys…", comment: ""))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.neutral7)
                }
            }
            .frame(minWidth: 180)
            .frame(height: 32)
            .padding(.horizontal, DesignSpacing.xxxs)
            .background(Color.neutral1)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.sm)
                    .stroke(Color.primary8, lineWidth: 2)
            )

            Button(action: { saveShortcut(for: action.id) }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 28, height: 28)
                    .background(recordingKeys.isEmpty ? Color.neutral5 : Color.primary8)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
            }
            .buttonStyle(.plain)
            .disabled(recordingKeys.isEmpty)

            Button(action: { cancelEditing() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.neutral9)
                    .frame(width: 28, height: 28)
                    .background(Color.neutral1)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm)
                            .stroke(Color.neutral3, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        if let error = validationError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Color.danger8)
                .padding(.top, 2)
        }
    }

    private func startEditing(_ actionId: String) {
        cancelEditing()
        editingActionId = actionId
        heldKeys = []
        recordingKeys = []
        validationError = nil
        HotkeySystem.shared.enterCaptureMode()
        HotkeySystem.shared.captureCallback = { [self] event in
            handleCaptureEvent(event)
        }
    }

    private func handleCaptureEvent(_ event: CaptureKeyEvent) {
        switch event.type {
        case .down:
            heldKeys.insert(event.key)
            validationError = nil
            rebuildRecordingKeys()
        case .up:
            heldKeys.remove(event.key)
        }
    }

    private func rebuildRecordingKeys() {
        var mods: [String] = []
        var main: String?
        for k in heldKeys {
            if ShortcutKey.isModifier(k) { mods.append(k) }
            else { main = k }
        }
        recordingKeys = main != nil ? mods + [main!] : mods
    }

    private func saveShortcut(for actionId: String) {
        guard !recordingKeys.isEmpty else { cancelEditing(); return }
        let shortcutString = formatShortcut(recordingKeys)

        if let error = ShortcutValidator.validate(shortcutString) {
            validationError = error
            return
        }
        if let conflict = store.conflictingAction(for: shortcutString, excluding: actionId) {
            validationError = String(format: NSLocalizedString("Already used by %@", comment: ""), conflict)
            return
        }
        if ShortcutTargetParser.parse(actionId: actionId, shortcut: shortcutString) == nil {
            validationError = NSLocalizedString("Unsupported key combination", comment: "")
            return
        }

        store.updateShortcuts(actionId: actionId, shortcuts: [shortcutString])
        cancelEditing()
        HotkeySystem.shared.reloadShortcuts()
    }

    private func cancelEditing() {
        editingActionId = nil
        heldKeys = []
        recordingKeys = []
        validationError = nil
        HotkeySystem.shared.captureCallback = nil
        HotkeySystem.shared.exitCaptureMode()
    }
}

// MARK: - 3. Audio (hardware / sound)

private struct AudioCard: View {
    @State private var inputDevices: [AudioInputDevice] = []
    private var config: ConfigStore { ConfigStore.shared }

    /// Whether the user-selected device is currently offline.
    private var selectedDeviceOffline: Bool {
        guard let uid = config.selectedMicrophoneId, !uid.isEmpty else { return false }
        return !inputDevices.contains { $0.uid == uid }
    }

    var body: some View {
        SettingsCard(title: NSLocalizedString("Audio", comment: "")) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingRow(NSLocalizedString("Microphone", comment: ""), description: NSLocalizedString("Audio input device", comment: ""))
                    if selectedDeviceOffline {
                        Text(NSLocalizedString("Selected device is offline — will use System Default", comment: ""))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warning8)
                    }
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { config.selectedMicrophoneId ?? "" },
                    set: { newValue in
                        let uid = newValue.isEmpty ? nil : newValue
                        config.set(selectedMicrophoneId: uid)
                        // Switch standby engine to the new device immediately.
                        RecordingCoordinator.shared.switchAudioDevice(to: uid)
                    }
                )) {
                    Text(NSLocalizedString("System Default", comment: "")).tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .onAppear { refreshDevices() }
            .onReceive(NotificationCenter.default.publisher(for: .audioDeviceListChanged)) { _ in
                refreshDevices()
            }

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Sound Effects", comment: ""), description: NSLocalizedString("Play sounds when recording starts/stops", comment: ""))
                Spacer()
                Toggle("", isOn: config.soundEffectsBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Mute System Audio", comment: ""), description: NSLocalizedString("Silence system sounds while recording", comment: ""))
                Spacer()
                Toggle("", isOn: config.muteSystemBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)
        }
    }

    private func refreshDevices() {
        inputDevices = AudioEngine.listInputDevices()

        // If user had selected a device that's now gone, auto-reset to System Default
        if let uid = config.selectedMicrophoneId, !uid.isEmpty,
           !inputDevices.contains(where: { $0.uid == uid }) {
            // Keep the stored preference (device may come back online),
            // but the warning label tells the user what's happening.
        }
    }
}

// MARK: - 4. Integration (AI & webhook)

private struct IntegrationCard: View {
    var body: some View {
        SettingsCard(title: NSLocalizedString("Integration", comment: "")) {
            HStack(alignment: .top) {
                SettingRow(NSLocalizedString("AI Post-processing", comment: ""), description: NSLocalizedString("Text is automatically refined by Xisper's AI after recognition. Always enabled.", comment: ""))
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.success8)
            }
            .padding(.vertical, 8)

            CardDivider()

            WebhookInlineSection()
        }
    }
}

/// Webhook rows inlined into Integration card (no card wrapper)
private struct WebhookInlineSection: View {
    @AppStorage("xisper.webhook.enabled")      private var enabled  = false
    @AppStorage("xisper.webhook.url")          private var url      = ""
    @AppStorage("xisper.webhook.method")       private var method   = "POST"
    @AppStorage("xisper.webhook.bodyTemplate") private var bodyTemplate = #"{"text":"{{text}}","timestamp":"{{timestamp}}"}"#

    @State private var testStatus: String?
    @State private var isTesting  = false

    var body: some View {
        HStack(alignment: .center) {
            SettingRow(NSLocalizedString("Webhook", comment: ""), description: NSLocalizedString("Send HTTP request after each transcription", comment: ""))
            Spacer()
            Toggle("", isOn: $enabled).labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 8)

        if enabled {
            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Endpoint URL", comment: ""))
                Spacer()
                TextField(NSLocalizedString("https://example.com/webhook", comment: ""), text: $url)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Method", comment: ""))
                Spacer()
                Picker("", selection: $method) {
                    Text("POST").tag("POST")
                    Text("PUT").tag("PUT")
                    Text("PATCH").tag("PATCH")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.vertical, 8)

            CardDivider()

            VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                SettingRow(NSLocalizedString("Body Template", comment: ""))

                TextEditor(text: $bodyTemplate)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .frame(height: 80)
                    .padding(4)
                    .background(Color.neutral1)
                    .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm).stroke(Color.neutral3))

                Text(NSLocalizedString("Variables: {{text}}, {{rawText}}, {{timestamp}}, {{duration}}, {{sessionId}}", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.neutral7)
            }
            .padding(.vertical, 8)

            HStack {
                Spacer()
                if let status = testStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(status.contains("OK") ? Color.success8 : Color.danger8)
                }
                Button(action: sendTestWebhook) {
                    if isTesting {
                        ProgressView().controlSize(.small).frame(width: 40)
                    } else {
                        Text(NSLocalizedString("Send Test", comment: ""))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .disabled(url.isEmpty || isTesting)
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSpacing.xxs)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.sm)
                        .fill(Color.primary8.opacity(url.isEmpty || isTesting ? 0.4 : 1.0))
                )
                .foregroundStyle(Color.onPrimary)
            }
            .padding(.top, 4)
        }
    }

    private func sendTestWebhook() {
        guard let reqURL = URL(string: url) else {
            testStatus = NSLocalizedString("Invalid URL", comment: ""); return
        }
        isTesting = true
        testStatus = nil

        let sampleBody = bodyTemplate
            .replacingOccurrences(of: "{{text}}", with: NSLocalizedString("Test transcription", comment: ""))
            .replacingOccurrences(of: "{{rawText}}", with: NSLocalizedString("Test transcription", comment: ""))
            .replacingOccurrences(of: "{{timestamp}}", with: ISO8601DateFormatter().string(from: Date()))
            .replacingOccurrences(of: "{{duration}}", with: "3.5")
            .replacingOccurrences(of: "{{sessionId}}", with: UUID().uuidString)

        var req = URLRequest(url: reqURL)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = sampleBody.data(using: .utf8)

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    testStatus = code >= 200 && code < 300 ? "✓ \(code) \(NSLocalizedString("OK", comment: ""))" : "✗ \(code)"
                    isTesting  = false
                }
            } catch {
                await MainActor.run {
                    testStatus = String(format: NSLocalizedString("Error: %@", comment: ""), error.localizedDescription)
                    isTesting  = false
                }
            }
        }
    }
}

// MARK: - 5. Account (user + system meta)

private struct AccountCard: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var userEmail = ""
    @State private var userName = ""
    @State private var currentTier = "free"
    @State private var isUpgrading = false
    @State private var upgradeError: String?
    @State private var manageError: String?

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return AppEnvironment.isDevBackend ? "\(version)-beta" : version
    }

    var body: some View {
        SettingsCard(title: NSLocalizedString("Account & System", comment: "")) {
            // User info row
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary8)
                        .frame(width: 36, height: 36)
                    Text(userInitials)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.onPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                    Text(userName.isEmpty ? NSLocalizedString("User", comment: "") : userName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.neutral12)

                        // Tier badge (non-free users)
                        if currentTier.lowercased() != "free" {
                            Text(currentTier.capitalized)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(currentTier.tierBadgeColor, in: Capsule())
                        }
                    }
                    Text(userEmail.isEmpty ? NSLocalizedString("user@example.com", comment: "") : userEmail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.neutral7)
                        .lineLimit(1)
                }

                Spacer()

                // Upgrade button (free users only)
                if currentTier.lowercased() == "free" {
                    VStack(spacing: 4) {
                        upgradeButton
                        if let error = upgradeError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.danger8)
                                .lineLimit(2)
                                .frame(maxWidth: 140)
                        }
                    }
                }

                Button {
                    Task { await AuthManager.shared.logout() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 12))
                        Text(NSLocalizedString("Sign Out", comment: ""))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.danger8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm)
                            .stroke(Color.neutral3, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)

            // Manage subscription (pro+ users)
            if currentTier.lowercased() != "free" {
                CardDivider()
                manageSubscriptionRow
            }

            CardDivider()

            // Launch at Login
            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Launch at Login", comment: ""), description: NSLocalizedString("Start automatically when you log in", comment: ""))
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)

            CardDivider()

            // Version
            HStack(alignment: .center) {
                Text(NSLocalizedString("Version", comment: ""))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.neutral9)
                Spacer()
                HStack(spacing: 6) {
                    Text(versionString)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.neutral12)
                    if AppEnvironment.isDevBackend {
                        Text("BETA")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            userEmail = AuthManager.shared.userEmail ?? ""
            userName = extractUserName(from: userEmail)
            currentTier = UsageManager.shared.tier
        }
        .onChange(of: UsageManager.shared.tier) { _, newTier in
            currentTier = newTier
        }
    }

    // MARK: - Upgrade Button

    @ViewBuilder
    private var upgradeButton: some View {
        Button {
            isUpgrading = true
            upgradeError = nil
            Task {
                await PaymentManager.shared.startUpgrade()
                if let error = PaymentManager.shared.lastError {
                    upgradeError = error
                    // Token expired → prompt re-login
                    if error.contains("Not authenticated") {
                        upgradeError = NSLocalizedString("Session expired, please sign out and sign in again", comment: "")
                    }
                }
                isUpgrading = false
            }
        } label: {
            HStack(spacing: 4) {
                if isUpgrading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                }
                Text(NSLocalizedString("Upgrade to Pro", comment: ""))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.onPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary8, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
        }
        .buttonStyle(.plain)
        .disabled(isUpgrading)
    }

    // MARK: - Manage Subscription Row

    @ViewBuilder
    private var manageSubscriptionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Subscription", comment: ""))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.neutral12)
                    Text(subscriptionDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.neutral7)
                }
                Spacer()

                Button {
                    manageError = nil
                    Task {
                        await PaymentManager.shared.openBillingPortal()
                        manageError = PaymentManager.shared.lastError
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                        Text(NSLocalizedString("Manage", comment: ""))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.primary8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm)
                            .stroke(Color.neutral3, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            if let error = manageError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
    }

    private var subscriptionDescription: String {
        let mgr = UsageManager.shared
        if mgr.subscriptionCancelAtPeriodEnd, let end = mgr.subscriptionPeriodEnd {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            return String(format: NSLocalizedString("Cancels on %@", comment: ""), fmt.string(from: end))
        }
        if let end = mgr.subscriptionPeriodEnd {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            return String(format: NSLocalizedString("Renews on %@", comment: ""), fmt.string(from: end))
        }
        return NSLocalizedString("Manage billing and subscription", comment: "")
    }

    // MARK: - Helpers

    private var userInitials: String {
        let name = userName.isEmpty ? NSLocalizedString("User", comment: "") : userName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func extractUserName(from email: String) -> String {
        let local = email.split(separator: "@").first ?? ""
        return String(local).capitalized
    }
}

// MARK: - Section style modifier (kept for legacy compat)

extension View {
    func sectionStyle() -> some View {
        self
            .padding(.top, DesignSpacing.xxs)
            .overlay(alignment: .bottom) {
                Color.neutral3.frame(height: 1)
            }
    }
}
