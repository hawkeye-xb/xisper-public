/**
 * WebhookView
 *
 * Webhook configuration.
 * Mirrors settings/WebhookSettings.tsx.
 */

import SwiftUI

private enum WebhookKeys {
    static let enabled      = "xisper.webhook.enabled"
    static let url          = "xisper.webhook.url"
    static let method       = "xisper.webhook.method"
    static let headers      = "xisper.webhook.headers"
    static let bodyTemplate = "xisper.webhook.bodyTemplate"
}

struct WebhookView: View {

    @AppStorage(WebhookKeys.enabled)      private var enabled  = false
    @AppStorage(WebhookKeys.url)          private var url      = ""
    @AppStorage(WebhookKeys.method)       private var method   = "POST"
    @AppStorage(WebhookKeys.bodyTemplate) private var bodyTemplate = #"{"text":"{{text}}","timestamp":"{{timestamp}}"}"#

    @State private var testStatus: String?
    @State private var isTesting  = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: NSLocalizedString("Webhook", comment: ""))

            HStack(alignment: .center) {
                SettingRow(NSLocalizedString("Enable Webhook", comment: ""), description: NSLocalizedString("Send HTTP request after each transcription", comment: ""))
                Spacer()
                Toggle("", isOn: $enabled).labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.vertical, 10)

            if enabled {
                Color.neutral3.frame(height: 1)

                HStack(alignment: .center) {
                    SettingRow(NSLocalizedString("Endpoint URL", comment: ""), description: nil)
                    Spacer()
                    TextField(NSLocalizedString("https://example.com/webhook", comment: ""), text: $url)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                .padding(.vertical, 10)

                Color.neutral3.frame(height: 1)

                HStack(alignment: .center) {
                    SettingRow(NSLocalizedString("Method", comment: ""), description: nil)
                    Spacer()
                    Picker("", selection: $method) {
                        Text("POST").tag("POST")
                        Text("PUT").tag("PUT")
                        Text("PATCH").tag("PATCH")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                .padding(.vertical, 10)

                Color.neutral3.frame(height: 1)

                VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                    SettingRow(NSLocalizedString("Body Template", comment: ""), description: nil)

                    TextEditor(text: $bodyTemplate)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .frame(height: 80)
                        .padding(4)
                        .background(Color.neutral1)
                        .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm).stroke(Color.neutral3))

                    Text(NSLocalizedString("Variables: {{text}}, {{rawText}}, {{timestamp}}, {{duration}}, {{sessionId}}", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.neutral7)
                }
                .padding(.vertical, 10)

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
                .padding(.top, 6)
            }
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
        req.httpBody   = sampleBody.data(using: .utf8)

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
