/**
 * WebhookClient
 *
 * Fires an HTTP request after each transcription commit.
 * Supports GET/POST with a customisable body template.
 * Template variables: {{text}}, {{rawText}}, {{timestamp}},
 *                     {{duration}}, {{recordingMode}}
 *
 * Retries: 3 attempts with exponential back-off (1s, 2s, 4s).
 *
 * Mirrors webhook/webhook-client.ts.
 */

import Foundation

// MARK: - Config keys (must match WebhookView)

private enum WHKeys {
    static let enabled      = "xisper.webhook.enabled"
    static let url          = "xisper.webhook.url"
    static let method       = "xisper.webhook.method"
    static let bodyTemplate = "xisper.webhook.bodyTemplate"
}

// MARK: - Payload

struct WebhookPayload {
    let text:          String
    let rawText:       String
    let timestamp:     Date
    let duration:      TimeInterval
    let recordingMode: String
}

// MARK: - WebhookClient

enum WebhookClient {

    /// Environment-specific UserDefaults
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) ?? .standard
    }

    static func fire(payload: WebhookPayload) async {
        guard defaults.bool(forKey: WHKeys.enabled),
              let urlString = defaults.string(forKey: WHKeys.url),
              !urlString.isEmpty,
              let url = URL(string: urlString)
        else { return }

        let method   = defaults.string(forKey: WHKeys.method)       ?? "POST"
        let template = defaults.string(forKey: WHKeys.bodyTemplate) ??
            #"{"text":"{{text}}","timestamp":"{{timestamp}}"}"#

        let body = render(template: template, payload: payload)

        await send(url: url, method: method, body: body, attempt: 1)
    }

    // MARK: - Private

    private static func send(url: URL, method: String, body: String, attempt: Int) async {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(AppEnvironment.appDisplayName)-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        if method != "GET", let data = body.data(using: .utf8) {
            request.httpBody = data
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode >= 400, http.statusCode < 500 {
                // 4xx: permanent failure — don't retry.
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                throw URLError(.badServerResponse)
            }
            // Success.
        } catch {
            guard attempt < 3 else { return }
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            await send(url: url, method: method, body: body, attempt: attempt + 1)
        }
    }

    private static func render(template: String, payload: WebhookPayload) -> String {
        let iso = ISO8601DateFormatter()
        return template
            .replacingOccurrences(of: "{{text}}",          with: jsonEscape(payload.text))
            .replacingOccurrences(of: "{{rawText}}",       with: jsonEscape(payload.rawText))
            .replacingOccurrences(of: "{{timestamp}}",     with: iso.string(from: payload.timestamp))
            .replacingOccurrences(of: "{{duration}}",      with: String(format: "%.2f", payload.duration))
            .replacingOccurrences(of: "{{recordingMode}}", with: jsonEscape(payload.recordingMode))
    }

    private static func jsonEscape(_ str: String) -> String {
        // Minimal JSON string escaping (no surrounding quotes).
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }
}
