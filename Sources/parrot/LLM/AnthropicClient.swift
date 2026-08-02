import Foundation

/// The Anthropic Messages API.
///
/// Structured answers ride as a forced tool call: `tool_choice` names the tool,
/// so the model has no way to reply with prose instead, and the arguments come
/// back already shaped. Asking for JSON in the prompt and hoping is the
/// alternative, and it fails exactly when the model has something chatty to say.
struct AnthropicClient: LLMClient {
    var name: String { "anthropic (\(model))" }

    private let model: String
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init(model: String) {
        self.model = model
    }

    func complete(_ request: LLMRequest) async throws -> String {
        guard let key = Keychain.apiKey(for: .anthropic) else {
            throw LLMError.missingAPIKey(.anthropic)
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        // The user turn carries everything untrusted. Nothing dictated and
        // nothing scraped is ever concatenated into `system`.
        let body = Body(
            model: model,
            maxTokens: request.maxOutputTokens,
            system: request.system,
            messages: [.init(role: "user", content: request.user)],
            tools: request.schema.map { [Tool($0)] },
            toolChoice: request.schema.map { .init(type: "tool", name: $0.name) }
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
        if decoded.stopReason == "refusal" { throw LLMError.refused }

        if request.schema != nil {
            guard let input = decoded.content.first(where: { $0.type == "tool_use" })?.input else {
                throw LLMError.badResponse("model answered without using the tool")
            }
            return String(data: try JSONEncoder().encode(input), encoding: .utf8) ?? ""
        }

        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw LLMError.badResponse("empty response") }
        return text
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
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let tools: [Tool]?
        let toolChoice: ToolChoice?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, tools
            case maxTokens = "max_tokens"
            case toolChoice = "tool_choice"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct ToolChoice: Encodable {
        let type: String
        let name: String
    }

    private struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONSchemaObject

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }

        init(_ schema: LLMSchema) {
            self.name = schema.name
            self.description = schema.description
            self.inputSchema = JSONSchemaObject(schema)
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
            let input: JSONObject?
        }
    }

    private struct APIError: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}

/// `{"type":"object","properties":{…},"required":[…]}` — the one schema shape
/// both APIs take, encoded once rather than by hand at each call site.
struct JSONSchemaObject: Encodable {
    let type = "object"
    let properties: [String: Property]
    let required: [String]
    /// OpenAI's strict mode rejects a schema that permits extra keys.
    let additionalProperties = false

    init(_ schema: LLMSchema) {
        var properties: [String: Property] = [:]
        for property in schema.properties {
            properties[property.name] = Property(
                description: property.description,
                enumValues: property.allowedValues
            )
        }
        self.properties = properties
        self.required = schema.required
    }

    struct Property: Encodable {
        let type = "string"
        let description: String
        let enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }
}

/// Just enough of a JSON value to carry a tool call's arguments back out
/// without knowing their shape at compile time.
enum JSONObject: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONObject])
    case array([JSONObject])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: JSONObject].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONObject].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "unrecognised JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
