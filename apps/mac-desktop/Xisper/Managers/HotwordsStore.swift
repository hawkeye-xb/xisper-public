import Foundation

/// Manages user-defined ASR hotwords with remote-first storage.
///
/// **Server-authoritative**: all mutations (add/delete/import) go through the API first.
/// Local file at `~/Library/Application Support/XisperHotwords/hotwords.json` is a cache
/// for fast UI rendering on startup.
@Observable
@MainActor
final class HotwordsStore {

    static let shared = HotwordsStore()

    private(set) var hotwords: [HotwordItem] = []
    private(set) var isLoading = false
    var error: String?

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(AppEnvironment.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("Hotwords", isDirectory: true)
            .appendingPathComponent("hotwords.json")
    }()

    // MARK: - Init

    private init() {
        loadLocalCache()
        Task { await fetch() }
    }

    // MARK: - Public API

    enum AddResult {
        case ok(HotwordItem)
        case tooLong
        case duplicate
        case empty
        case networkError(String)
    }

    /// Add a hotword via API. Returns result after server confirms.
    @discardableResult
    func add(text: String) async -> AddResult {
        let normalised = HotwordItem.normalise(text)
        guard !normalised.isEmpty else { return .empty }
        guard normalised.count <= HotwordItem.maxCharacters else { return .tooLong }
        // Quick client-side duplicate check (server also enforces)
        guard !hotwords.contains(where: { $0.text == normalised }) else { return .duplicate }

        let id = UUID().uuidString
        let body: [String: Any] = ["items": [["id": id, "text": normalised]]]

        do {
            let (data, response) = try await apiRequestWithRetry("POST", path: "/api/v1/hotwords", json: body)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    return .networkError("Hotword limit reached")
                }
                if http.statusCode >= 400 {
                    let msg = parseError(data) ?? "Server error (\(http.statusCode))"
                    return .networkError(msg)
                }
            }
            // Parse response to check for duplicates
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let duplicates = json["duplicates"] as? [String], !duplicates.isEmpty {
                return .duplicate
            }
            let now = Date()
            let item = HotwordItem(id: id, text: normalised, createdAt: now, updatedAt: now)
            hotwords.insert(item, at: 0)
            saveLocalCache()
            return .ok(item)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Delete a hotword via API.
    func delete(id: String) async {
        do {
            let (_, response) = try await apiRequestWithRetry("DELETE", path: "/api/v1/hotwords/\(id)")
            if let http = response as? HTTPURLResponse, http.statusCode < 300 {
                hotwords.removeAll { $0.id == id }
                saveLocalCache()
            }
        } catch {
            showError("Failed to delete: \(error.localizedDescription)")
        }
    }

    /// Delete all hotwords via API.
    struct DeleteAllResult {
        var success: Bool
        var deleted: Int
        var errorMessage: String?
    }

    func deleteAll() async -> DeleteAllResult {
        let count = hotwords.count
        do {
            let (data, response) = try await apiRequestWithRetry("DELETE", path: "/api/v1/hotwords/all")
            if let http = response as? HTTPURLResponse, http.statusCode < 300 {
                let deleted = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["deleted"] as? Int ?? count
                hotwords.removeAll()
                saveLocalCache()
                return DeleteAllResult(success: true, deleted: deleted)
            }
            let msg = parseError(data) ?? "Server error (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            return DeleteAllResult(success: false, deleted: 0, errorMessage: msg)
        } catch {
            return DeleteAllResult(success: false, deleted: 0, errorMessage: error.localizedDescription)
        }
    }

    /// Delete at offsets (for SwiftUI List). Fires API calls for each.
    func delete(at offsets: IndexSet) async {
        let ids = offsets.map { hotwords[$0].id }
        for id in ids {
            await delete(id: id)
        }
    }

    /// Import result for batch add.
    struct ImportResult {
        var added: Int
        var skipped: Int
        var failed: Int
        var errorMessage: String?
    }

    /// Import hotwords via API. Sends texts to server for dedup + insert.
    func importFromTexts(_ texts: [String]) async -> ImportResult {
        let cleaned = texts
            .map { HotwordItem.normalise($0) }
            .filter { !$0.isEmpty && $0.count <= HotwordItem.maxCharacters }

        guard !cleaned.isEmpty else {
            return ImportResult(added: 0, skipped: 0, failed: texts.count, errorMessage: "No valid hotwords found in file")
        }

        let body: [String: Any] = ["items": cleaned]
        do {
            let (data, response) = try await apiRequestWithRetry("POST", path: "/api/v1/hotwords/import", json: body)
            if let http = response as? HTTPURLResponse {
                CrashLogger.log("HotwordsStore", "import response status=\(http.statusCode) body=\(String(data: data.prefix(500), encoding: .utf8) ?? "nil")")
                if http.statusCode < 300,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let imported = json["imported"] as? Int ?? 0
                    let skipped = json["skipped"] as? Int ?? 0
                    if imported > 0 { await fetch() }
                    return ImportResult(added: imported, skipped: skipped, failed: 0)
                }
                let serverMsg = parseError(data) ?? "Server error (HTTP \(http.statusCode))"
                return ImportResult(added: 0, skipped: 0, failed: cleaned.count, errorMessage: serverMsg)
            }
            return ImportResult(added: 0, skipped: 0, failed: cleaned.count, errorMessage: "No response from server")
        } catch {
            return ImportResult(added: 0, skipped: 0, failed: cleaned.count, errorMessage: error.localizedDescription)
        }
    }

    /// Fetch all hotwords from server. Updates local cache.
    func fetch() async {
        guard AuthManager.shared.isAuthenticated else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let (data, response) = try await apiRequestWithRetry("GET", path: "/api/v1/hotwords")
            guard let http = response as? HTTPURLResponse else {
                CrashLogger.log("HotwordsStore", "fetch() no HTTP response")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                CrashLogger.log("HotwordsStore", "fetch() HTTP \(http.statusCode) body=\(body)")
                let serverMsg = parseError(data)
                showError(serverMsg ?? "Failed to load hotwords (HTTP \(http.statusCode))")
                return
            }
            let decoded = try JSONDecoder().decode(HotwordsListResponse.self, from: data)
            hotwords = decoded.items.map { item in
                HotwordItem(
                    id: item.id,
                    text: item.text,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(item.updatedAt) / 1000)
                )
            }
            saveLocalCache()
            error = nil
            CrashLogger.log("HotwordsStore", "fetch() ok, count=\(hotwords.count)")
        } catch {
            CrashLogger.log("HotwordsStore", "fetch() failed", error: error)
            // Keep local cache, don't clear hotwords
        }
    }

    /// Export hotwords from server as text array.
    func exportTexts() async -> [String] {
        do {
            let (data, response) = try await apiRequestWithRetry("GET", path: "/api/v1/hotwords/export")
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [String] else {
                return hotwords.map(\.text) // Fallback to local cache
            }
            return items
        } catch {
            return hotwords.map(\.text) // Fallback to local cache
        }
    }

    // MARK: - Local Cache

    private func loadLocalCache() {
        CrashLogger.log("HotwordsStore", "loadLocalCache() start")
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([HotwordItem].self, from: data)
            hotwords = decoded.sorted { $0.updatedAt > $1.updatedAt }
            CrashLogger.log("HotwordsStore", "loadLocalCache() ok, count=\(hotwords.count)")
        } catch {
            CrashLogger.log("HotwordsStore", "loadLocalCache() failed (starting fresh)", error: error)
            hotwords = []
        }
    }

    private func saveLocalCache() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(hotwords)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            CrashLogger.log("HotwordsStore", "saveLocalCache() failed", error: error)
        }
    }

    // MARK: - Networking

    /// Makes an API request, automatically retrying once with a refreshed token on 401.
    private func apiRequestWithRetry(_ method: String, path: String, json: [String: Any]? = nil) async throws -> (Data, URLResponse) {
        let (data, response) = try await apiRequest(method, path: path, json: json)

        // Auto-retry on 401: refresh token and try once more
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            CrashLogger.log("HotwordsStore", "\(method) \(path) got 401, refreshing token...")
            do {
                try await AuthManager.shared.refreshAccessToken()
            } catch {
                CrashLogger.log("HotwordsStore", "token refresh failed", error: error)
                return (data, response) // Return original 401 response
            }
            return try await apiRequest(method, path: path, json: json)
        }

        return (data, response)
    }

    private func apiRequest(_ method: String, path: String, json: [String: Any]? = nil) async throws -> (Data, URLResponse) {
        let baseURL = AuthManager.shared.serviceBaseURL
        guard let token = AuthManager.shared.loadToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let json = json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        return try await URLSession.shared.data(for: req)
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }

    private func showError(_ msg: String) {
        error = msg
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { if error == msg { error = nil } }
        }
    }

    // MARK: - Response Models

    private struct HotwordsListResponse: Decodable {
        let items: [RemoteHotwordItem]
        let total: Int
    }

    private struct RemoteHotwordItem: Decodable {
        let id: String
        let text: String
        let createdAt: Int
        let updatedAt: Int
    }
}
