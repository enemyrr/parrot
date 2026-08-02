import Foundation

/// The models a cleanup provider will actually accept, asked of the provider
/// rather than kept in a list here.
///
/// A hardcoded list is wrong the week after it ships, and typing an id from
/// memory is worse — a typo comes back as an opaque 404 in the middle of
/// someone's dictation. The account's own list is the only thing that knows
/// which models this particular key can call.
enum CleanupModels {
    struct Model: Identifiable, Equatable {
        /// What goes in the request. This is the setting's value.
        let id: String
        /// What the provider calls it where it has a name for it; OpenAI only
        /// ships ids, so for OpenAI the two are the same string.
        let displayName: String
    }

    enum ListError: Error, CustomStringConvertible {
        case missingAPIKey(Keychain.Account)
        case badResponse(String)

        var description: String {
            switch self {
            case .missingAPIKey(let account): return "no \(account.displayName) API key"
            case .badResponse(let detail): return detail
            }
        }
    }

    /// Providers that run locally have nothing to list and return empty.
    static func fetch(for provider: LLMProvider) async throws -> [Model] {
        guard let account = provider.keychainAccount else { return [] }
        guard let key = Keychain.apiKey(for: account) else {
            throw ListError.missingAPIKey(account)
        }
        switch provider {
        case .apple: return []
        case .openai: return try await openAIModels(from: get(openAIRequest(key: key)))
        case .anthropic: return try await anthropicModels(from: get(anthropicRequest(key: key)))
        }
    }

    // MARK: - OpenAI

    private static func openAIRequest(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func openAIModels(from data: Data) throws -> [Model] {
        let decoded = try decode(OpenAIList.self, from: data)
        return decoded.data
            .filter { isChatModel($0.id) }
            // Newest first: the model someone is reaching for is nearly always
            // one of the last few OpenAI shipped, and the raw list arrives in
            // no useful order at all.
            .sorted { a, b in
                a.created == b.created ? a.id < b.id : (a.created ?? 0) > (b.created ?? 0)
            }
            .map { Model(id: $0.id, displayName: $0.id) }
    }

    /// `/v1/models` is everything the account can reach — image, audio,
    /// embedding, moderation — and the Responses API rejects nearly all of it.
    /// Anything that gets through this filter wrongly is still recoverable:
    /// the picker keeps a way to type an id by hand.
    static func isChatModel(_ id: String) -> Bool {
        let id = id.lowercased()
        let families = ["gpt-", "chatgpt-", "o1", "o3", "o4"]
        guard families.contains(where: id.hasPrefix) else { return false }
        // Same prefix, different job. `instruct` and `codex` are chat-capable
        // but not what a prose rewrite wants.
        let excluded = [
            "audio", "realtime", "transcribe", "tts", "image", "search",
            "embedding", "moderation", "instruct", "codex",
        ]
        return !excluded.contains { id.contains($0) }
    }

    private struct OpenAIList: Decodable {
        let data: [Entry]

        struct Entry: Decodable {
            let id: String
            /// Epoch seconds. Optional so an entry without one still decodes.
            let created: Int?
        }
    }

    // MARK: - Anthropic

    private static func anthropicRequest(key: String) -> URLRequest {
        // The default page is 20, which cuts the list off mid-family.
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// Already newest-first from the API, and every entry is a chat model, so
    /// there is nothing to sort or filter.
    static func anthropicModels(from data: Data) throws -> [Model] {
        try decode(AnthropicList.self, from: data).data
            .map { Model(id: $0.id, displayName: $0.displayName ?? $0.id) }
    }

    private struct AnthropicList: Decodable {
        let data: [Entry]

        struct Entry: Decodable {
            let id: String
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
    }

    // MARK: - Transport

    private static func get(_ request: URLRequest) async throws -> Data {
        var request = request
        request.httpMethod = "GET"
        // This runs while someone is looking at a settings window, so it fails
        // fast rather than leaving a spinner up for the URLSession default.
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ListError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw ListError.badResponse(errorDetail(status: http.statusCode, data: data))
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ListError.badResponse("couldn't read the model list")
        }
    }

    /// Both providers wrap failures the same way.
    private static func errorDetail(status: Int, data: Data) -> String {
        if let err = try? JSONDecoder().decode(APIError.self, from: data) {
            return "HTTP \(status): \(err.error.message)"
        }
        return "HTTP \(status)"
    }

    private struct APIError: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}
