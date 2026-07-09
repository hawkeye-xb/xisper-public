/**
 * PaymentManager
 *
 * Handles Creem payment flows:
 *   - Upgrade: POST /checkout/create → open browser → URL scheme callback
 *   - Billing portal: POST /subscription/portal → open browser
 *
 * No polling. Tier detection relies on:
 *   1. URL scheme callback (immediate): xisper-mac://payment-success
 *   2. UsageManager 5-min auto-refresh (fallback)
 *   3. Server-side resolveUserTier on every API request (enforcement)
 */

import AppKit
import Foundation

@Observable
@MainActor
final class PaymentManager {

    static let shared = PaymentManager()

    private(set) var isProcessing = false
    private(set) var lastError: String?

    private var serviceBaseURL: String { AuthManager.shared.serviceBaseURL }

    private init() {}

    // MARK: - Upgrade

    /// Request a short-lived ticket, then open the pricing page in browser.
    /// The ticket is opaque and expires in 5 min — no JWT exposed in the URL.
    func startUpgrade() async {
        paymentLog("startUpgrade — BEGIN")
        isProcessing = true
        lastError = nil

        defer {
            paymentLog("startUpgrade — END, lastError=\(lastError ?? "nil")")
            if lastError != nil { isProcessing = false }
        }

        let token: String
        do {
            token = try await AuthManager.shared.getValidToken()
        } catch {
            paymentLog("startUpgrade — getValidToken FAILED: \(error)")
            lastError = "Not authenticated"
            return
        }

        // 1. Request a pricing ticket from backend
        let ticketEndpoint = "\(serviceBaseURL)/api/v1/pricing/ticket"
        var req = URLRequest(url: URL(string: ticketEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, httpResp) = try await URLSession.shared.data(for: req)
            let status = (httpResp as? HTTPURLResponse)?.statusCode ?? -1

            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ticket = json["ticket"] as? String
            else {
                lastError = parseError(from: data) ?? "Failed to create pricing session (HTTP \(status))"
                return
            }

            // 2. Open pricing page with opaque ticket (not JWT)
            let pricingURL = "\(serviceBaseURL)/api/v1/pricing?t=\(ticket)"
            guard let url = URL(string: pricingURL) else {
                lastError = "Invalid pricing URL"
                return
            }

            paymentLog("startUpgrade — opening pricing page with ticket")
            UsageManager.shared.markAwaitingPayment()
            NSWorkspace.shared.open(url)
        } catch {
            paymentLog("startUpgrade — network error: \(error)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - URL Scheme Callback

    /// Called when xisper-mac://payment-success is received.
    func handlePaymentCallback() {
        paymentLog("handlePaymentCallback — received")
        isProcessing = false

        Task {
            // 1. Reconcile subscription with Creem API (ensures backend DB is up-to-date
            //    even if webhook hasn't arrived yet)
            await UsageManager.shared.reconcileAndRefresh()

            // 2. Retry after 3s — webhook may still be in-flight
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await UsageManager.shared.reconcileAndRefresh()
        }
    }

    // MARK: - Billing Portal

    /// Fetch portal URL from backend → open in browser.
    func openBillingPortal() async {
        lastError = nil

        guard let token = try? await AuthManager.shared.getValidToken() else {
            lastError = "Not authenticated"
            return
        }

        var req = URLRequest(url: URL(string: "\(serviceBaseURL)/api/v1/subscription/portal")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, httpResp) = try await URLSession.shared.data(for: req)
            let status = (httpResp as? HTTPURLResponse)?.statusCode ?? -1

            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let portalURLStr = json["portal_url"] as? String,
                  let portalURL = URL(string: portalURLStr)
            else {
                let body = String(data: data, encoding: .utf8) ?? ""
                paymentLog("openBillingPortal FAILED — HTTP \(status) body=\(body.prefix(200))")
                lastError = parseError(from: data) ?? "Billing portal unavailable (HTTP \(status))"
                return
            }

            paymentLog("openBillingPortal — opening portal")
            NSWorkspace.shared.open(portalURL)
        } catch {
            paymentLog("openBillingPortal — error: \(error)")
            lastError = "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func parseError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String
        else { return nil }
        return error
    }
}

private func paymentLog(_ msg: String) {
    #if DEBUG
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[PaymentManager \(ts)] \(msg)")
    #endif
}
