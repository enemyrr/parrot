import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT via FluidAudio's CoreML pipeline, ANE-accelerated.
///
/// Unlike Whisper, the TDT transducer emits nothing for silence — no
/// `[BLANK_AUDIO]`/`(music)` tokens to strip — so a short noisy hotkey tap
/// produces an empty transcript rather than an invented one.
actor ParakeetTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    /// Script hint for the decoder. See `LanguageSelection` — this constrains
    /// the alphabet tokens may come from, not which language is recognised.
    private let language: Language?
    private var manager: AsrManager?
    private var decoderLayers = 2

    init(model: TranscriptionModel, language: Language? = nil) {
        self.modelID = model.id
        self.model = model
        self.language = language
    }

    func warmUp() async throws {
        if manager != nil { return }
        guard let engineModelID = model.engineModelID else {
            throw TranscriberError.missingEngineID
        }
        let version = Self.version(for: engineModelID)

        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let models = try await AsrModels.downloadAndLoad(version: version)
        // melChunkContext is an English long-form fix that skews v3's
        // multilingual decoder back toward its English prior; FluidAudio
        // recommends disabling it for v3. Only matters past the ~30s
        // chunking threshold, i.e. hands-free recordings.
        let config = ASRConfig(melChunkContext: version == .v2)
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)

        self.manager = manager
        self.decoderLayers = models.version.decoderLayers
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }

        // Fresh decoder state per utterance — each hotkey press is independent,
        // so carrying state across would leak context between dictations.
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func version(for engineModelID: String) -> AsrModelVersion {
        engineModelID.hasSuffix("v2") ? .v2 : .v3
    }
}
