import Foundation

struct TranslateLanguageOption: Identifiable, Hashable {
    let id: String
    let label: String
}

@Observable
final class TranslateSettings {

    static let shared = TranslateSettings()

    static let languages: [TranslateLanguageOption] = [
        .init(id: "auto",  label: "Auto"),
        .init(id: "en",    label: "English"),
        .init(id: "zh-CN", label: "Chinese (Simplified)"),
        .init(id: "ja",    label: "Japanese"),
        .init(id: "ko",    label: "한국어"),
        .init(id: "fr",    label: "Français"),
        .init(id: "de",    label: "Deutsch"),
        .init(id: "es",    label: "Español"),
    ]

    private(set) var targetLanguage: String

    /// Environment-specific UserDefaults
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) ?? .standard
    }

    private init() {
        let saved = Self.defaults.string(forKey: Keys.target)
        if let saved {
            targetLanguage = saved
        } else {
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            targetLanguage = code.hasPrefix("zh") ? "en" : "zh-CN"
        }
    }

    func set(targetLanguage v: String) {
        targetLanguage = v
        Self.defaults.set(v, forKey: Keys.target)
    }

    /// Build the translation instruction for the LLM prompt.
    func getTranslationInstruction() -> String {
        if targetLanguage == "auto" {
            return [
                "If the text is in Chinese, translate to English.",
                "If the text is in English, translate to Chinese.",
                "Otherwise, translate to English.",
            ].joined(separator: "\n")
        }

        let langNames: [String: String] = [
            "en": "English", "zh-CN": "Simplified Chinese",
            "ja": "Japanese", "ko": "Korean",
            "fr": "French", "de": "German", "es": "Spanish",
        ]
        let name = langNames[targetLanguage] ?? "English"
        return "Translate the result into \(name). If the input is already in \(name), keep it as-is."
    }

    private enum Keys {
        static let target = "xisper.translateTargetLanguage"
    }
}
