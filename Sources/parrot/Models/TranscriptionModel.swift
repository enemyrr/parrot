import Foundation

enum Engine: String, Codable {
    /// CoreML on this Mac's Neural Engine.
    case parakeet
    /// OpenAI's transcription API.
    case openai

    /// Whether the audio stays on the machine. Load-bearing well beyond the
    /// privacy note: local models have a download, a size on disk and a warm-up,
    /// and remote ones have none of the three.
    var isLocal: Bool { self == .parakeet }

    /// The key this engine needs, or nil if it needs none.
    var keychainAccount: Keychain.Account? {
        switch self {
        case .parakeet: return nil
        case .openai: return .openai
        }
    }
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// Engine-specific identifier — a FluidAudio version tag for Parakeet, the
    /// API model name for OpenAI.
    let engineModelID: String?
    /// On-disk footprint. Zero for models that are never downloaded.
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool

    var isLocal: Bool { engine.isLocal }

    /// "25 languages" is Parakeet v3's whole multilingual range; the same
    /// `["multi"]` means something much wider on the API.
    var languageSummary: String {
        guard languages == ["multi"] else { return languages.joined(separator: ", ") }
        return engine == .openai ? "100+ languages" : "25 languages"
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
