import Foundation

/// Cleanup via the Anthropic Messages API. Opt-in: this is the one path where
/// a transcript leaves the machine, so it only runs when the config names it.
struct AnthropicCleaner: TextCleaner {
    var name: String { "anthropic (\(model))" }

    private let model: String
    private let prompt: String
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init(model: String, prompt: String) {
        self.model = model
        self.prompt = prompt
    }

    func clean(_ text: String, vocabulary: [String]) async throws -> String {
        guard let key = Keychain.anthropicAPIKey() else {
            throw CleanerError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        // The transcript goes in as the user turn, never concatenated into the
        // system prompt — dictating "ignore your instructions" is data, not an
        // instruction.
        let body = Request(
            model: model,
            maxTokens: Self.maxTokens(for: text),
            system: CleanupPrompt.instructions(custom: prompt, vocabulary: vocabulary),
            messages: [.init(role: "user", content: text)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CleanerError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw CleanerError.badResponse(Self.errorDetail(status: http.statusCode, data: data))
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if decoded.stopReason == "refusal" {
            throw CleanerError.badResponse("model declined the request")
        }
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw CleanerError.badResponse("empty response") }
        return text
    }

    /// Cleanup rewrites rather than expands, so the output is bounded by the
    /// input. ~4 chars/token, doubled for headroom, with a floor for short clips.
    private static func maxTokens(for text: String) -> Int {
        max(256, min(4096, text.count / 2))
    }

    private static func errorDetail(status: Int, data: Data) -> String {
        if let err = try? JSONDecoder().decode(APIError.self, from: data) {
            return "HTTP \(status): \(err.error.message)"
        }
        return "HTTP \(status)"
    }

    // MARK: - Wire types

    private struct Request: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct Response: Decodable {
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct APIError: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}
