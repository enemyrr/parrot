import Foundation
import FoundationModels

/// Apple's on-device model.
///
/// The reason squawk can exist without a privacy asterisk: with this provider
/// the screen contents never leave the Mac. Slower and less capable than the
/// API models on a long reply, and worth it for anyone who would otherwise not
/// turn the feature on at all.
///
/// Structured answers are asked for in the prompt rather than enforced by a
/// schema. `SquawkResponse` parses leniently and falls back on the selection
/// rule when the model answers with bare prose, which is the common failure and
/// a harmless one.
struct AppleLLMClient: LLMClient {
    let name = "apple (on-device)"

    func complete(_ request: LLMRequest) async throws -> String {
        guard #available(macOS 26, *) else {
            throw LLMError.unavailable("the Apple provider needs macOS 26 or later")
        }
        if let reason = AppleCleanupAvailability.unavailableReason {
            throw LLMError.unavailable(reason)
        }

        var instructions = request.system
        if let schema = request.schema {
            instructions += "\n\n" + Self.jsonInstruction(for: schema)
        }

        let session = LanguageModelSession(instructions: instructions)
        // Deterministic: the same instruction against the same screen should
        // not produce a different answer each time it is asked.
        let options = GenerationOptions(temperature: 0)
        let response = try await session.respond(to: request.user, options: options)
        return response.content
    }

    private static func jsonInstruction(for schema: LLMSchema) -> String {
        let fields = schema.properties.map { property -> String in
            let allowed = property.allowedValues.map { " (one of: \($0.joined(separator: ", ")))" } ?? ""
            return "  \"\(property.name)\": \(property.description)\(allowed)"
        }.joined(separator: "\n")
        return """
            Reply with a single JSON object and nothing else — no prose before \
            it, no code fence around it:
            {
            \(fields)
            }
            """
    }
}
