import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
enum ModelRegistry {
    // sizeMB is the CoreML on-disk footprint. The HF model cards don't publish
    // it, so v3 is measured from a real download; v2 shares the architecture
    // and a tighter vocabulary, so it lands in the same neighbourhood.
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "parakeet-v3",
            displayName: "Parakeet TDT 0.6B v3 (multilingual)",
            engine: .parakeet,
            engineModelID: "parakeet-tdt-0.6b-v3",
            sizeMB: 461,
            languages: ["multi"],
            recommended: true
        ),
        TranscriptionModel(
            id: "parakeet-v2",
            displayName: "Parakeet TDT 0.6B v2 (English)",
            engine: .parakeet,
            engineModelID: "parakeet-tdt-0.6b-v2",
            sizeMB: 461,
            languages: ["en"],
            recommended: false
        ),
        // The one model here that isn't a download. It exists for what Parakeet
        // structurally can't do: languages outside its 25, and vocabulary that
        // steers the decoder rather than being patched into its output
        // afterwards. It is slower than either local model — a round trip
        // against a fraction of a second on the ANE — so it is never the
        // recommendation, only the escape hatch.
        TranscriptionModel(
            id: "gpt-transcribe",
            displayName: "GPT Transcribe (OpenAI)",
            engine: .openai,
            engineModelID: "gpt-transcribe",
            sizeMB: 0,
            languages: ["multi"],
            recommended: false
        ),
    ]

    /// Model ids that used to exist. Kept so a LaunchAgent plist or shell alias
    /// written before the Parakeet switch doesn't hard-fail on startup.
    private static let retired: [String: String] = [
        "whisper-base.en": "parakeet-v3",
        "whisper-small.en": "parakeet-v3",
        "whisper-large-v3-turbo": "parakeet-v3",
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        if let m = shared.first(where: { $0.id == id }) { return m }
        guard let replacement = retired[id] else { return nil }
        FileHandle.standardError.write(Data(
            "note: \(id) has been retired; using \(replacement)\n".utf8
        ))
        return shared.first { $0.id == replacement }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
