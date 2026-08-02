import Foundation

/// One request to a language model, in the shape all three providers can take.
struct LLMRequest {
    /// The instructions. Never contains anything the user dictated or anything
    /// read off the screen — both of those are data, and data goes in `user`.
    var system: String
    var user: String
    var maxOutputTokens: Int
    /// OpenAI's reasoning knob. Empty means the model's own default.
    var reasoningEffort: String = ""
    /// When set, the provider is asked to answer with a single JSON object of
    /// this shape, and `complete` returns that JSON rather than prose.
    var schema: LLMSchema?
}

/// The sliver of JSON Schema squawk actually needs: a flat object of string
/// properties, some of them enumerations.
///
/// A general JSON Schema type would be a lot of machinery for one call site,
/// and each provider spells the same shape differently anyway.
struct LLMSchema {
    let name: String
    let description: String
    let properties: [Property]

    struct Property {
        let name: String
        let description: String
        /// Non-nil constrains the value to one of these.
        var allowedValues: [String]?
    }

    var required: [String] { properties.map(\.name) }
}

enum LLMError: Error, CustomStringConvertible {
    case unavailable(String)
    case missingAPIKey(Keychain.Account)
    case timedOut
    case badResponse(String)
    case refused

    var description: String {
        switch self {
        case .unavailable(let why): return why
        case .missingAPIKey(let account):
            return "no \(account.displayName) API key — add one in the Accounts tab "
                + "of `parrot settings`, or set \(account.envVar)"
        case .timedOut: return "timed out"
        case .badResponse(let detail): return detail
        case .refused: return "the model declined the request"
        }
    }
}

/// A provider that can answer a prompt.
///
/// The three implementations differ only in wire format; everything above this
/// line — prompt assembly, guards, timeouts — is shared.
protocol LLMClient {
    /// Human-readable, for stderr and `parrot doctor`.
    var name: String { get }
    func complete(_ request: LLMRequest) async throws -> String
}

/// Build the client a provider names, or say why it can't run here.
func makeLLMClient(
    provider: LLMProvider,
    model: String,
    reasoningEffort: String = ""
) -> Result<LLMClient, LLMError> {
    switch provider {
    case .apple:
        if #available(macOS 26, *), AppleCleanupAvailability.isAvailable {
            return .success(AppleLLMClient())
        }
        return .failure(.unavailable(
            AppleCleanupAvailability.unavailableReason ?? "the Apple provider is unavailable"
        ))
    case .anthropic:
        return .success(AnthropicClient(
            model: model.isEmpty ? AnthropicCleaner.defaultModel : model
        ))
    case .openai:
        return .success(OpenAIClient(
            model: model.isEmpty ? OpenAICleaner.defaultModel : model,
            reasoningEffort: reasoningEffort
        ))
    }
}

/// Runs a request with a deadline. A model that never answers must not leave a
/// recording stuck in "thinking" forever.
func withDeadline<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw LLMError.timedOut }
        return first
    }
}
