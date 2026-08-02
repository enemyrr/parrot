import Foundation

/// The OpenAI Responses API.
///
/// Structured answers use `text.format` with `strict: true`, which is enforced
/// during decoding rather than asked for in the prompt — the model cannot
/// produce a reply that doesn't fit the schema.
struct OpenAIClient: LLMClient {
    var name: String {
        reasoningEffort.isEmpty
            ? "openai (\(model))"
            : "openai (\(model), \(reasoningEffort) reasoning)"
    }

    private let model: String
    private let reasoningEffort: String
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(model: String, reasoningEffort: String) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    func complete(_ request: LLMRequest) async throws -> String {
        guard let key = Keychain.apiKey(for: .openai) else {
            throw LLMError.missingAPIKey(.openai)
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body = Body(
            model: model,
            instructions: request.system,
            input: request.user,
            maxOutputTokens: budget(for: request),
            reasoning: reasoningEffort.isEmpty ? nil : .init(effort: reasoningEffort),
            text: request.schema.map { .init(format: .init($0)) }
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw LLMError.badResponse(Self.errorDetail(status: http.statusCode, data: data))
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if decoded.status == "incomplete" {
            throw LLMError.badResponse(
                "response incomplete (\(decoded.incompleteDetails?.reason ?? "unknown reason"))"
            )
        }
        let content = decoded.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if content.contains(where: { $0.type == "refusal" }) { throw LLMError.refused }

        let text = content.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw LLMError.badResponse("empty response") }
        return text
    }

    private func budget(for request: LLMRequest) -> Int {
        request.maxOutputTokens + OpenAIBudget.reasoningHeadroom(effort: reasoningEffort)
    }

    private static func errorDetail(status: Int, data: Data) -> String {
        if let err = try? JSONDecoder().decode(APIError.self, from: data) {
            return "HTTP \(status): \(err.error.message)"
        }
        return "HTTP \(status)"
    }

    // MARK: - Wire types

    private struct Body: Encodable {
        let model: String
        let instructions: String
        let input: String
        let maxOutputTokens: Int
        let reasoning: Reasoning?
        let text: TextFormat?

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, reasoning, text
            case maxOutputTokens = "max_output_tokens"
        }

        struct Reasoning: Encodable {
            let effort: String
        }

        struct TextFormat: Encodable {
            let format: Format

            struct Format: Encodable {
                let type = "json_schema"
                let name: String
                let strict = true
                let schema: JSONSchemaObject

                init(_ schema: LLMSchema) {
                    self.name = schema.name
                    self.schema = JSONSchemaObject(schema)
                }
            }
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

/// How much of `max_output_tokens` to set aside for thinking.
///
/// On the Responses API reasoning tokens are billed against the *same* budget
/// as the answer, and they are spent first. Get this wrong and the request
/// comes back `incomplete: max_output_tokens` with an empty message — the model
/// thought its way through the entire allowance and had nothing left to write
/// with.
///
/// The trap is the unset case. "Not set" omits the `reasoning` parameter, which
/// means *the model's own default effort*, not *no reasoning* — so a reasoning
/// model reasons anyway and needs the most headroom of all, not the least.
/// Reserving nothing there is what broke cleanup on long dictations.
///
/// Shared by the cleanup path and the squawk client because it is one fact
/// about one API, and two copies of it drift.
enum OpenAIBudget {
    static func reasoningHeadroom(effort: String) -> Int {
        switch effort {
        case "minimal": return 1_024
        case "low": return 2_048
        case "medium": return 4_096
        case "high": return 8_192
        // Unset: the model decides, so assume it decides to think.
        default: return 4_096
        }
    }
}
