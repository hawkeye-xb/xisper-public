/**
 * RetranscribeService
 *
 * Re-sends a saved WAV file through ASR + LLM postprocess pipeline,
 * then updates the existing TranscribeRecord in SwiftData.
 *
 * Flow:
 *   1. Read WAV from disk → extract PCM (skip 44-byte header)
 *   2. Open ASR WebSocket → stream PCM in 12800-byte chunks (400ms, 2ms apart)
 *   3. Wait for final ASR result (dynamic timeout: 15s + sendTime * 5)
 *   4. Run ITN + LLM postprocess
 *   5. Update record in SwiftData
 */

import Foundation

enum RetranscribeError: LocalizedError {
    case fileNotFound
    case fileTooSmall
    case asrFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .fileNotFound:       return "Audio file not found"
        case .fileTooSmall:       return "Audio file is too small"
        case .asrFailed(let msg): return "ASR failed: \(msg)"
        case .notAuthenticated:   return "Not authenticated"
        }
    }
}

@MainActor
enum RetranscribeService {

    private static let chunkSize = 12800  // bytes per chunk (400ms at 16kHz/16bit/mono)
    private static let chunkDelay: UInt64 = 2_000_000  // 2ms in nanoseconds
    private static let baseTimeout: TimeInterval = 15.0  // base timeout in seconds
    private static let timeoutMultiplier = 5.0  // additional time = sendTime * 5

    /// Retranscribe a record from its saved WAV file.
    /// Returns the new processed text on success.
    static func retranscribe(record: TranscribeRecord) async throws -> (processed: String, raw: String) {
        let token = try await AuthManager.shared.getValidToken()

        // 1. Read WAV file
        let filePath = record.audioFilePath
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw RetranscribeError.fileNotFound
        }

        let wavData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        guard wavData.count > 44 else {
            throw RetranscribeError.fileTooSmall
        }

        // Skip 44-byte WAV header to get raw PCM
        let pcmData = wavData.subdata(in: 44..<wavData.count)

        // 2. Send to ASR
        let rawText = try await sendToASR(pcmData: pcmData, token: token, actionId: record.actionId)

        // If ASR still returns empty, clear the service error marker
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.transcribeContent = "[No speech detected]"
            record.rawTranscribeContent = ""
            return (processed: "[No speech detected]", raw: "")
        }

        // 3. ITN + LLM postprocess
        let itnText = InverseTextNormalizer.normalize(rawText)
        var finalText = itnText

        if itnText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            let isTranslateMode = record.actionId == "translate"
            let corrections = IdentityManager.shared.activeCorrections
            let userHotwords = HotwordsStore.shared.hotwords.map(\.text)
            let identityHotwords = IdentityManager.shared.activeHotwordTexts
            let allHotwords = Array(Set(userHotwords + identityHotwords))
            let identityLabel = IdentityManager.shared.activeLabel
            let identityDesc = IdentityManager.shared.activeDescription
            let identityContext = identityLabel != nil ? "\(identityLabel!)\(identityDesc.map { " — \($0)" } ?? "")" : nil

            // Use current ASR language from ConfigStore for LLM model selection
            let currentLanguage = ConfigStore.shared.asrLanguage

            do {
                if isTranslateMode {
                    let instruction = TranslateSettings.shared.getTranslationInstruction()
                    finalText = try await withTimeout(seconds: 8) {
                        try await LLMPostprocessClient.process(
                            rawText: itnText,
                            corrections: corrections.isEmpty ? nil : corrections,
                            hotwords: allHotwords.isEmpty ? nil : allHotwords,
                            voiceMode: "translation",
                            translationInstruction: instruction,
                            speechLanguage: currentLanguage,
                            identityContext: identityContext,
                            identityId: IdentityManager.shared.activeIdentityId
                        )
                    }
                } else {
                    finalText = try await withTimeout(seconds: 8) {
                        try await LLMPostprocessClient.process(
                            rawText: itnText,
                            corrections: corrections.isEmpty ? nil : corrections,
                            hotwords: allHotwords.isEmpty ? nil : allHotwords,
                            speechLanguage: currentLanguage,
                            identityContext: identityContext,
                            identityId: IdentityManager.shared.activeIdentityId
                        )
                    }
                }
            } catch {
                // LLM failed — use ITN text as fallback
                finalText = itnText
            }
        }

        // 4. Update SwiftData record
        // The record is already managed by the caller's ModelContext (@Query).
        // We update it in place; the caller's context will auto-save.
        record.transcribeContent = finalText
        record.rawTranscribeContent = rawText

        return (processed: finalText, raw: rawText)
    }

    // MARK: - Public reusable ASR from PCM

    /// Send raw PCM data to ASR and return the final transcript.
    /// Reusable by both retranscribe (from WAV) and auto-retry (from in-memory buffer).
    ///
    /// Uses larger chunks (12800 bytes = 400ms) and shorter delay (2ms) for faster burst-send.
    /// Dynamic timeout: baseTimeout + sendTime * timeoutMultiplier
    static func transcribeFromPCM(pcmData: Data, config: ConfigStore, recordingId: String? = nil) async throws -> String {
        let token = try await AuthManager.shared.getValidToken()

        let client = ASRClient()
        let vocabularyId = IdentityManager.shared.activeVocabularyId

        let userHotwords = HotwordsStore.shared.hotwords.map(\.text)
        let activeIdentityId = IdentityManager.shared.activeIdentityId

        let asrConfig = ASRSessionConfig(
            language: config.asrLanguage,
            sampleRate: 16_000,
            format: "pcm",
            vocabularyId: vocabularyId,
            hotwords: userHotwords.isEmpty ? nil : userHotwords,
            identityId: activeIdentityId,
            recordingId: recordingId,
            retranscribe: true
        )

        let baseURL = asrBaseURL
        client.connect(token: token, baseURL: baseURL)
        client.sendStart(config: asrConfig)

        // Calculate estimated send time and dynamic timeout
        // chunkSize = 12800 bytes = 0.4 seconds of audio at 16kHz/16bit/mono
        // chunkDelay = 2ms = 0.002 seconds
        let chunkCount = ceil(Double(pcmData.count) / Double(chunkSize))
        let sendTimeSec = chunkCount * 0.002  // 2ms per chunk
        let dynamicTimeout = baseTimeout + sendTimeSec * timeoutMultiplier

        // Stream PCM data in chunks with delay
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            client.sendAudio(chunk)
            offset = end
            if offset < pcmData.count {
                try? await Task.sleep(nanoseconds: chunkDelay)
            }
        }

        client.sendFinish()

        do {
            let text = try await client.waitForFinal(timeout: dynamicTimeout)
            client.close()
            return text
        } catch {
            client.close()
            throw RetranscribeError.asrFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private static func sendToASR(pcmData: Data, token: String, actionId: String?) async throws -> String {
        try await transcribeFromPCM(pcmData: pcmData, config: ConfigStore.shared)
    }

    private static var asrBaseURL: String { AppEnvironment.serviceBaseURL }

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LLMPostprocessError.disabled
            }
            guard let result = try await group.next() else { throw LLMPostprocessError.disabled }
            group.cancelAll()
            return result
        }
    }
}
