/**
 * LLMPostprocessClient
 *
 * Sends raw ASR text to the Xisper backend for LLM post-processing.
 * Uses the user's auth token — no API keys required.
 *
 * Backend endpoint: POST /api/v1/llm/postprocess
 */

import Foundation

// MARK: - Error

enum LLMPostprocessError: LocalizedError {
    case disabled
    case notAuthenticated
    case httpError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .disabled:                  return "LLM post-processing is disabled"
        case .notAuthenticated:          return "Not signed in"
        case .httpError(let c, let m):   return "Server error \(c): \(m)"
        case .decodingError:             return "Response decoding failed"
        }
    }
}

// MARK: - PostprocessContext

struct PostprocessContext {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    var url: String?
    var selectedText: String?
}

// MARK: - LLMPostprocessClient

enum LLMPostprocessClient {

    /// Returns the post-processed text, or throws.
    /// - Parameters:
    ///   - voiceMode: "dictation" for normal, "translation" for translate action.
    ///   - translationInstruction: Translation target instruction (only for translation mode).
    ///   - speechLanguage: Speech recognition language (e.g., "zh-CN", "en-US") for model selection.
    static func process(
        rawText: String,
        context: PostprocessContext? = nil,
        corrections: [CorrectionRule]? = nil,
        hotwords: [String]? = nil,
        voiceMode: String = "dictation",
        translationInstruction: String? = nil,
        speechLanguage: String? = nil,
        identityContext: String? = nil,
        identityId: String? = nil
    ) async throws -> String {
        let token = try await AuthManager.shared.getValidToken()

        guard let url = URL(string: "\(serviceBaseURL)/api/v1/llm/postprocess") else {
            throw LLMPostprocessError.decodingError
        }

        var body: [String: Any] = [
            "text": rawText,
            "stream": false,
            "config": [
                "mode": "clean",
                "voiceMode": voiceMode,
                "features": [
                    "correction": true,
                    "formatting": true,
                    "hotwords": true,
                    "rewrite": false
                ] as [String: Any]
            ] as [String: Any]
        ]

        if let lang = speechLanguage {
            body["speechLanguage"] = lang
        }

        if let instruction = translationInstruction {
            body["translationInstruction"] = instruction
        }

        if let ctx = context {
            var ctxDict: [String: Any] = [:]
            if let name = ctx.appName {
                ctxDict["app"] = ["name": name, "bundleId": ctx.bundleId ?? ""] as [String: Any]
            }
            if let title = ctx.windowTitle { ctxDict["windowTitle"] = title }
            if let u     = ctx.url         { ctxDict["url"] = u }
            if let sel   = ctx.selectedText { ctxDict["selectedText"] = sel }
            if !ctxDict.isEmpty { body["context"] = ctxDict }
        }

        if let corrections = corrections, !corrections.isEmpty {
            body["corrections"] = corrections.map { rule -> [String: Any] in
                var dict: [String: Any] = ["correct": rule.correct]
                if let m = rule.misheard, !m.isEmpty { dict["misheard"] = m }
                if let n = rule.note, !n.isEmpty { dict["note"] = n }
                return dict
            }
        }

        if let hotwords = hotwords, !hotwords.isEmpty {
            body["hotwords"] = hotwords
        }

        if let ic = identityContext, !ic.isEmpty {
            body["identityContext"] = ic
        }

        if let iid = identityId, !iid.isEmpty {
            body["identityId"] = iid
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"

        print("[LLMPostprocess] HTTP \(statusCode), voiceMode=\(voiceMode), body=\(bodyString.prefix(500))")

        if statusCode >= 400 {
            throw LLMPostprocessError.httpError(statusCode, bodyString)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMPostprocessError.decodingError
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let resultObj = json["result"] as? [String: Any],
           let text = resultObj["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("[LLMPostprocess] Unexpected response structure: \(json.keys)")
        throw LLMPostprocessError.decodingError
    }

    private static var serviceBaseURL: String { AppEnvironment.serviceBaseURL }
}
