import ArgumentParser
import Foundation

/// `parrot transcribe meeting.m4a` — the engine, pointed at a file instead of
/// the microphone.
///
/// The transcript goes to stdout and everything else to stderr, so it pipes and
/// redirects like any other tool. Needs no daemon: it loads its own copy of the
/// model, which costs a few seconds up front and is the price of working in a
/// terminal with nothing else running.
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio or video file."
    )

    @Argument(help: "Audio or video file to transcribe.")
    var file: String

    @Option(name: .shortAndLong, help: "Write the transcript here instead of stdout.")
    var output: String?

    @Flag(name: .long, help: "Write <name>.txt next to the source file.")
    var save: Bool = false

    @Flag(name: .long, help: "Run the cleanup pass over the transcript.")
    var clean: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the configured one.")
    var model: String?

    func run() throws {
        LegacyConfigMigration.runIfNeeded()

        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No file at \(url.path).")
        }

        let settings = SettingsStore.current()
        let chosen: TranscriptionModel
        if let model {
            guard let found = ModelRegistry.find(model) else {
                throw ValidationError("Unknown model '\(model)'. See `parrot models list`.")
            }
            chosen = found
        } else {
            chosen = settings.resolvedModel
        }

        var cleaner: TextCleaner?
        if clean {
            switch makeCleaner(for: settings.cleanup) {
            case .success(let made): cleaner = made
            case .failure(let error):
                // Not fatal. The transcript is the thing that was asked for, and
                // losing it because the optional repair pass can't run would be
                // the wrong trade.
                warn("cleanup unavailable — \(error)")
            }
        }

        let language = chosen.engine == .parakeet
            ? LanguageSelection.resolve(settings.languages).language
            : nil
        let wordlist = Wordlist(settings: settings.wordlist)
        let pipeline = FileTranscription(
            transcriber: makeTranscriber(for: chosen, language: language),
            wordlist: wordlist,
            cleaner: cleaner,
            cleanup: settings.cleanup,
            store: settings.history.enabled ? TranscriptStore(settings: settings.history) : nil,
            languages: LanguageSelection.displayNames(settings.languages),
            // No shortcut triggers: expansion doesn't run on this path, so
            // asking the decoder to listen for the phrases that drive it would
            // steer the transcript toward words nothing is going to act on.
            transcription: TranscriptionContext(
                vocabulary: wordlist.vocabulary,
                languages: settings.languages
            ),
            modelID: chosen.id
        )

        warn("\(url.lastPathComponent) · \(chosen.id)")

        let result = runBlocking { () -> Result<FileTranscription.Outcome, Error> in
            do {
                return .success(try await pipeline.run(url: url) { stage in
                    warn(stage.label)
                })
            } catch {
                return .failure(error)
            }
        }

        let outcome: FileTranscription.Outcome
        switch result {
        case .success(let value): outcome = value
        case .failure(let error):
            warn("failed: \(Self.describe(error))")
            throw ExitCode(1)
        }

        let words = outcome.text.split(whereSeparator: \.isWhitespace).count
        warn(String(
            format: "✓ %@ of audio in %.1fs · %d words%@",
            Self.clock(outcome.seconds), outcome.elapsed, words,
            outcome.cleaned ? " · cleaned" : ""
        ))

        if let destination = destinationURL(for: url) {
            do {
                try (outcome.text + "\n").write(to: destination, atomically: true, encoding: .utf8)
                warn("→ \(destination.path)")
            } catch {
                // Print it anyway rather than lose a transcript that took two
                // minutes to make because a directory wasn't writable.
                warn("couldn't write \(destination.path): \(error.localizedDescription)")
                print(outcome.text)
                throw ExitCode(1)
            }
        } else {
            print(outcome.text)
        }
    }

    /// Where the transcript goes, or nil for stdout. `--output` wins over
    /// `--save` — it's the more specific of the two.
    private func destinationURL(for source: URL) -> URL? {
        if let output {
            return URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        }
        guard save else { return nil }
        return source.deletingPathExtension().appendingPathExtension("txt")
    }

    /// Progress and findings go to stderr so `parrot transcribe x.m4a > out.txt`
    /// captures the transcript and nothing else.
    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// The three error families this path can produce all describe themselves;
    /// anything else falls back to the raw value rather than "an error occurred".
    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as FileTranscription.FileError: return error.description
        case let error as AudioFileReader.ReadError: return error.description
        case let error as TranscriberError: return error.description
        default: return "\(error)"
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
    }
}
