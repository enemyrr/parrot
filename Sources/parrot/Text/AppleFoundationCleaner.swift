import Foundation
import FoundationModels

/// Cleanup via Apple's on-device model. No API key, no network, no cost — the
/// transcript never leaves the machine, which is why this is the default.
@available(macOS 26, *)
struct AppleFoundationCleaner: TextCleaner {
    let name = "apple (on-device)"
    private let prompt: String

    init(prompt: String) {
        self.prompt = prompt
    }

    /// Whether the model can actually run here. Apple Intelligence being off,
    /// the device being ineligible, or the model still downloading all present
    /// as a usable framework with an unusable model.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off — enable it in System Settings"
        case .unavailable(.deviceNotEligible):
            return "this Mac can't run Apple Intelligence; set provider = \"anthropic\""
        case .unavailable(.modelNotReady):
            return "the on-device model is still downloading"
        case .unavailable:
            return "the on-device model is unavailable"
        }
    }

    func clean(_ text: String, context: CleanupContext) async throws -> String {
        if let reason = Self.unavailableReason {
            throw CleanerError.unavailable(reason)
        }
        let session = LanguageModelSession(
            instructions: CleanupPrompt.instructions(custom: prompt, context: context)
        )
        // Deterministic: two identical dictations should clean identically.
        let options = GenerationOptions(temperature: 0)
        let response = try await session.respond(to: text, options: options)
        return response.content
    }
}
