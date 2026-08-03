import AppKit
import Foundation
import UniformTypeIdentifiers

/// One file transcription, as observable state.
///
/// A singleton because two places start the same job — the menu bar's
/// "Transcribe File…" and the drop zone in the Transcribe pane — and the second
/// one has to be able to show the progress of a run the first one started.
/// Without shared state, picking a file from the menu bar would open a window
/// that knew nothing about the work already in flight.
@MainActor
final class FileTranscriptionJob: ObservableObject {
    static let shared = FileTranscriptionJob()

    struct Outcome {
        let source: URL
        let text: String
        /// Length of the recording.
        let seconds: Double
        /// How long the transcription took.
        let elapsed: Double
        let cleaned: Bool
        let model: String

        var words: Int { text.split(whereSeparator: \.isWhitespace).count }

        /// Where "Save" writes by default: the recording's name with a .txt on
        /// it, in the folder the recording came from.
        var defaultDestination: URL {
            source.deletingPathExtension().appendingPathExtension("txt")
        }
    }

    enum State {
        case idle
        case running(file: String, stage: String)
        case done(Outcome)
        case failed(file: String, reason: String)
    }

    @Published private(set) var state: State = .idle

    /// The cleanup pass, off unless asked for. Unlike dictation — see
    /// `FileTranscription.clean` for why an hour of transcript isn't a free
    /// thing to send a language model.
    @Published var cleanUp = false

    /// The daemon's already-warm engine, when there is a daemon. Set once at
    /// startup. Without it the job loads its own copy of the model, which is
    /// what `parrot settings` on its own does — slower on the first file, and
    /// the alternative is a pane that does nothing unless parrot is running.
    var liveEngine: (() -> Transcriber?)?

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Running

    func start(url: URL) {
        task?.cancel()

        let settings = SettingsStore.shared.settings
        let model = settings.resolvedModel
        let language = model.engine == .parakeet
            ? LanguageSelection.resolve(settings.languages).language
            : nil

        var cleaner: TextCleaner?
        if cleanUp, case .success(let made) = makeCleaner(for: settings.cleanup) {
            cleaner = made
        }

        let wordlist = Wordlist(settings: settings.wordlist)
        let pipeline = FileTranscription(
            transcriber: liveEngine?() ?? makeTranscriber(for: model, language: language),
            wordlist: wordlist,
            cleaner: cleaner,
            cleanup: settings.cleanup,
            store: settings.history.enabled ? TranscriptStore(settings: settings.history) : nil,
            languages: LanguageSelection.displayNames(settings.languages),
            // No shortcut triggers, for the same reason the CLI leaves them out:
            // nothing expands them on this path, so steering the decoder toward
            // them would only bend the transcript.
            transcription: TranscriptionContext(
                vocabulary: wordlist.vocabulary,
                languages: settings.languages
            ),
            modelID: model.id
        )

        let name = url.lastPathComponent
        state = .running(file: name, stage: FileTranscription.Stage.decoding.label)

        // Built out here rather than inline at the call: nesting a second
        // `[weak self]` inside the task's own would capture the outer capture,
        // which is a var, and a var read from two isolation domains is an error
        // under Swift 6 checking.
        let report: @Sendable (FileTranscription.Stage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.state = .running(file: name, stage: stage.label)
            }
        }

        task = Task { [weak self] in
            do {
                let outcome = try await pipeline.run(url: url, progress: report)
                guard !Task.isCancelled else { return }
                self?.state = .done(Outcome(
                    source: url,
                    text: outcome.text,
                    seconds: outcome.seconds,
                    elapsed: outcome.elapsed,
                    cleaned: outcome.cleaned,
                    model: outcome.model
                ))
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(file: name, reason: Self.describe(error))
            }
        }
    }

    /// Stops waiting for the result and clears the pane.
    ///
    /// Honest about what it can do: the decode is inside CoreML by then and
    /// finishes on its own either way. What this cancels is the work after it
    /// and anything being shown about it — nothing is stored, and nothing is
    /// reported.
    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: - Picking a file

    /// The open panel, shared by the menu bar and the pane's button.
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioFileReader.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Transcribe"
        panel.message = "Choose an audio or video file to transcribe."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as FileTranscription.FileError: return error.description
        case let error as AudioFileReader.ReadError: return error.description
        case let error as TranscriberError: return error.description
        default: return "\(error)"
        }
    }
}
