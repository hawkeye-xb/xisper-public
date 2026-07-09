/**
 * IdentityManager
 *
 * Fetches and caches identities from GET /api/v1/identities.
 * Persists active identity ID in UserDefaults.
 * Exposes activeVocabularyId for ASR, activeCorrections for LLM postprocess.
 */

import Foundation

// MARK: - Models

struct IdentityIndexItem: Decodable {
    let id: String
    let label: String
    let description: String?
    let enabled: Bool
    let updatedAt: Int
    let correctionCount: Int
    let vocabularyId: String?

    enum CodingKeys: String, CodingKey {
        case id, label, description, enabled, updatedAt, correctionCount, vocabularyId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        updatedAt = try c.decode(Int.self, forKey: .updatedAt)
        correctionCount = try c.decodeIfPresent(Int.self, forKey: .correctionCount) ?? 0
        vocabularyId = try c.decodeIfPresent(String.self, forKey: .vocabularyId)
    }
}

struct CorrectionRule: Decodable {
    let correct: String
    let misheard: [String]?
    let note: String?
}

struct IdentityDetail: Decodable {
    let id: String
    let label: String
    let description: String?
    let enabled: Bool
    let updatedAt: Int
    let correctionCount: Int
    let vocabularyId: String?
    let corrections: [CorrectionRule]
    let hotwords: [HotwordEntry]?

    struct HotwordEntry: Decodable {
        let text: String
        let weight: Int?
        let lang: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, label, description, enabled, updatedAt, correctionCount, vocabularyId, corrections, hotwords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        updatedAt = try c.decode(Int.self, forKey: .updatedAt)
        correctionCount = try c.decodeIfPresent(Int.self, forKey: .correctionCount) ?? 0
        vocabularyId = try c.decodeIfPresent(String.self, forKey: .vocabularyId)
        corrections = try c.decodeIfPresent([CorrectionRule].self, forKey: .corrections) ?? []
        hotwords = try c.decodeIfPresent([HotwordEntry].self, forKey: .hotwords)
    }
}

// MARK: - IdentityManager

@Observable
@MainActor
final class IdentityManager {

    static let shared = IdentityManager()

    /// UserDefaults key with environment suffix to separate beta/prod
    private static var activeIdKey: String {
        "xisper.active_identity_id.\(AppEnvironment.environmentName)"
    }
    private static let defaultIdentityId = "general-tech"

    /// Environment-specific UserDefaults
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) ?? .standard
    }

    private(set) var availableIdentities: [IdentityIndexItem] = []
    private(set) var activeIdentityId: String? = nil {
        didSet {
            if let id = activeIdentityId {
                Self.defaults.set(id, forKey: Self.activeIdKey)
            } else {
                Self.defaults.removeObject(forKey: Self.activeIdKey)
            }
        }
    }
    private(set) var identityCache: [String: IdentityDetail] = [:]
    private(set) var isLoading = false

    private init() {
        if let stored = Self.defaults.string(forKey: Self.activeIdKey), !stored.isEmpty {
            activeIdentityId = stored
        }
    }

    // MARK: - Public

    /// English label from server — used for LLM identityContext (keep English for better LLM understanding)
    var activeLabel: String? {
        guard let id = activeIdentityId else { return nil }
        return availableIdentities.first { $0.id == id }?.label ?? id
    }

    /// Localized label for UI display — maps identity ID to client-side translation, falls back to server label
    var activeLocalizedLabel: String? {
        guard let id = activeIdentityId else { return nil }
        let fallback = availableIdentities.first { $0.id == id }?.label ?? id
        return Self.localizedLabel(for: id, fallback: fallback)
    }

    /// Returns localized display name for an identity ID. Falls back to server label if no translation found.
    static func localizedLabel(for id: String, fallback: String) -> String {
        let key = "identity.\(id)"
        let localized = NSLocalizedString(key, comment: "Identity label")
        // If NSLocalizedString returns the key itself, no translation exists — use server fallback
        return localized == key ? fallback : localized
    }

    var activeDescription: String? {
        guard let id = activeIdentityId else { return nil }
        if let cached = identityCache[id] { return cached.description }
        return availableIdentities.first { $0.id == id }?.description
    }

    var activeVocabularyId: String? {
        guard let id = activeIdentityId else { return nil }
        if let cached = identityCache[id] { return cached.vocabularyId }
        return availableIdentities.first { $0.id == id }?.vocabularyId
    }

    var activeCorrections: [CorrectionRule] {
        guard let id = activeIdentityId, let cached = identityCache[id] else { return [] }
        return cached.corrections
    }

    /// Hotword texts from the active Identity (server-managed, e.g. domain terms).
    var activeHotwordTexts: [String] {
        guard let id = activeIdentityId, let cached = identityCache[id] else { return [] }
        return cached.hotwords?.map(\.text) ?? []
    }

    func setActiveIdentity(_ id: String?) {
        activeIdentityId = id
        if let id, !identityCache.keys.contains(id) {
            Task { await fetchIdentityDetail(id) }
        }
    }

    /// Fetches active identity detail if not yet cached. Call when entering Hotwords etc.
    func ensureActiveCached() async {
        guard let id = activeIdentityId, !identityCache.keys.contains(id) else { return }
        await fetchIdentityDetail(id)
    }

    func fetchAvailableIdentities() async {
        guard let token = try? await AuthManager.shared.getValidToken() else { return }

        CrashLogger.log("IdentityManager", "fetchAvailableIdentities start")
        isLoading = true
        defer { isLoading = false }

        let baseURL = serviceBaseURL
        guard let url = URL(string: "\(baseURL)/api/v1/identities") else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["data"] else { return }

            let decoded = try JSONSerialization.data(withJSONObject: raw)
            let list = try JSONDecoder().decode([IdentityIndexItem].self, from: decoded)
            availableIdentities = list.filter { $0.enabled }

            // Validate active ID still exists
            if let active = activeIdentityId {
                if !availableIdentities.contains(where: { $0.id == active }) {
                    activeIdentityId = nil
                }
            }

            // Auto-set default when none selected
            if activeIdentityId == nil, availableIdentities.contains(where: { $0.id == Self.defaultIdentityId }) {
                setActiveIdentity(Self.defaultIdentityId)
            }

            // Eager-load active identity detail
            if let id = activeIdentityId, identityCache[id] == nil {
                await fetchIdentityDetail(id)
            }
            CrashLogger.log("IdentityManager", "fetchAvailableIdentities done, count=\(availableIdentities.count)")
        } catch {
            CrashLogger.log("IdentityManager", "fetchAvailableIdentities failed", error: error)
            print("[IdentityManager] Failed to fetch identities: \(error)")
        }
    }

    func fetchIdentityDetail(_ id: String) async {
        guard let token = try? await AuthManager.shared.getValidToken() else { return }

        let baseURL = serviceBaseURL
        guard let url = URL(string: "\(baseURL)/api/v1/identities/\(id)") else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["data"] else { return }

            let decoded = try JSONSerialization.data(withJSONObject: raw)
            let detail = try JSONDecoder().decode(IdentityDetail.self, from: decoded)
            identityCache[id] = detail
            CrashLogger.log("IdentityManager", "fetchIdentityDetail ok id=\(id)")
        } catch {
            CrashLogger.log("IdentityManager", "fetchIdentityDetail failed id=\(id)", error: error)
            print("[IdentityManager] Failed to fetch identity \(id): \(error)")
        }
    }

    // MARK: - Private

    private var serviceBaseURL: String { AppEnvironment.serviceBaseURL }
}
