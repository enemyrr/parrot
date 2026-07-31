import Foundation

/// Cleanup via the OpenAI Responses API. Same opt-in stance as the Anthropic
/// path: the transcript only leaves the machine when the config names it.
struct OpenAICleaner: TextCleaner {
    var name: String {
        reasoningEffort.isEmpty
            ? "openai (\(model))"
            : "openai (\(model), \(reasoningEffort) reasoning)"
    }

    static let defaultModel = "gpt-5-mini"

    private let model: String
    /// "minimal" | "low" | "medium" | "high"; empty means the model's default.
    private let reasoningEffort: String
    private let prompt: String
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(model: String, reasoningEffort: String, prompt: String) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.prompt = prompt
    }

    func clean(_ text: String, context: CleanupContext) async throws -> String {
        guard let key = Keychain.apiKey(for: .openai) else {
            throw CleanerError.missingAPIKey(.openai)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        // Same split as the Anthropic path: the prompt rides as instructions,
        // the transcript as input — dictating "ignore your instructions" is
        // data, not an instruction.
        let body = Request(
            model: model,
            instructions: CleanupPrompt.instructions(custom: prompt, context: context),
            input: text,
            maxOutputTokens: maxOutputTokens(for: text),
            reasoning: reasoningEffort.isEmpty ? nil : .init(effort: reasoningEffort)
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
        if decoded.status == "incomplete" {
            let reason = decoded.incompleteDetails?.reason ?? "unknown reason"
            throw CleanerError.badResponse("response incomplete (\(reason))")
        }
        let content = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
        if content.contains(where: { $0.type == "refusal" }) {
            throw CleanerError.badResponse("model declined the request")
        }
        let cleaned = content
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        guard !cleaned.isEmpty else { throw CleanerError.badResponse("empty response") }
        return cleaned
    }

    /// Output is bounded by the input, as with the Anthropic cleaner — but on
    /// OpenAI reasoning tokens draw from the same budget, so a configured
    /// effort gets headroom on top or the model thinks its way to an empty
    /// reply.
    private func maxOutputTokens(for text: String) -> Int {
        let output = max(256, min(4096, text.count / 2))
        let thinking = reasoningEffort.isEmpty || reasoningEffort == "minimal" ? 0 : 4096
        return output + thinking
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
        let instructions: String
        let input: String
        let maxOutputTokens: Int
        let reasoning: Reasoning?

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, reasoning
            case maxOutputTokens = "max_output_tokens"
        }

        struct Reasoning: Encodable {
            let effort: String
        }
    }

    private struct Response: Decodable {
        let status: String?
        let incompleteDetails: IncompleteDetails?
        let output: [Item]

        enum CodingKeys: String, CodingKey {
            case status, output
            case incompleteDetails = "incomplete_details"
        }

        struct IncompleteDetails: Decodable {
            let reason: String?
        }

        /// The output array mixes reasoning items and the message; only the
        /// message carries text.
        struct Item: Decodable {
            let type: String
            let content: [Content]?
        }

        struct Content: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct APIError: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}
