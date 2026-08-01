import Foundation

/// What the transcriber is told about the audio beyond the samples.
///
/// Passed per call rather than fixed at construction because the things in it
/// change far more often than the engine does. Editing a wordlist entry has to
/// take effect on the next dictation; rebuilding the transcriber to deliver it
/// would mean reloading a CoreML model on every keystroke in the Dictionary
/// pane.
struct TranscriptionContext {
    /// Terms expected in the audio — names, jargon, product ids. A local
    /// decoder can't use them; the API takes them as keyword hints.
    let vocabulary: [String]
    /// Languages the speaker actually uses, as ISO codes.
    let languages: [String]

    static let empty = TranscriptionContext(vocabulary: [], languages: [])
}

protocol Transcriber {
    var modelID: String { get }
    /// Load the model into memory, downloading first if needed. Call once at
    /// startup so the first hotkey press isn't blocked on it.
    func warmUp() async throws
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> String
}

enum TranscriberError: Error, CustomStringConvertible {
    case missingEngineID
    case notLoaded
    case missingAPIKey(Keychain.Account)
    case audioTooLong(seconds: Double, limit: Double)
    case badResponse(String)

    var description: String {
        switch self {
        case .missingEngineID: return "model has no engine id"
        case .notLoaded: return "model not loaded"
        case .missingAPIKey(let account):
            return "no \(account.displayName) API key — add one in the Accounts tab "
                + "of `parrot settings`, or set \(account.envVar)"
        case .audioTooLong(let seconds, let limit):
            return String(
                format: "recording is %.0fs; the API takes at most %.0fs in one request",
                seconds, limit
            )
        case .badResponse(let detail): return "transcription failed: \(detail)"
        }
    }
}
