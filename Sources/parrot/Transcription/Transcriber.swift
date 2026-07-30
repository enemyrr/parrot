import Foundation

protocol Transcriber {
    var modelID: String { get }
    /// Load the model into memory, downloading first if needed. Call once at
    /// startup so the first hotkey press isn't blocked on it.
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
