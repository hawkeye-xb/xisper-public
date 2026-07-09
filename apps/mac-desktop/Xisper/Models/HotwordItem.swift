import Foundation

/// A single user-defined hotword for ASR hint injection.
///
/// Stored as a JSON array at `~/Library/Application Support/XisperHotwords/hotwords.json`
/// (same path as the Electron app, so hotwords survive channel switches and reinstalls).
struct HotwordItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String        // Normalised: trimmed, whitespace collapsed
    var createdAt: Date
    var updatedAt: Date

    static let maxCharacters = 64

    /// Normalises `input` the same way the Electron app does.
    static func normalise(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespaces)
             .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
