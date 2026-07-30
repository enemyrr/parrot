import Foundation

enum Engine: String, Codable {
    case parakeet
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// Engine-specific identifier (e.g. "parakeet-tdt-0.6b-v3" for FluidAudio).
    let engineModelID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
