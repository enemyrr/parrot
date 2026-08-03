import Foundation

/// Everything between "a file on disk" and "text you can keep":
///
///     decode → transcribe → wordlist → (cleanup) → store → return
///
/// The short half of `DictationPipeline`, and the parts it drops are dropped on
/// purpose. Shortcut expansion and entity tagging both exist to turn something
/// you *said* into something you meant — a trigger phrase, a name off the
/// window in front of you — and neither has any claim on a recording made an
/// hour ago in another room. Nothing is injected at the cursor either: the
/// result of a forty-minute file is not a keystroke.
struct FileTranscription {
    struct Outcome {
        /// Straight off the engine, before the wordlist and cleanup.
        let raw: String
        /// What to hand back — wordlist applied, cleaned if asked for.
        let text: String
        /// Length of the recording, not of the work.
        let seconds: Double
        /// How long the whole thing took.
        let elapsed: Double
        let cleaned: Bool
        let model: String
    }

    enum Stage {
        case decoding
        case transcribing
        case cleaning(chunk: Int, of: Int)

        var label: String {
            switch self {
            case .decoding: return "Reading the file…"
            case .transcribing: return "Transcribing…"
            case .cleaning(let chunk, let total):
                return total > 1 ? "Cleaning up (\(chunk) of \(total))…" : "Cleaning up…"
            }
        }
    }

    enum FileError: Error, CustomStringConvertible {
        case silence
        case tooLongForModel(seconds: Double, limit: Double, model: String)

        var description: String {
            switch self {
            case .silence:
                return "nothing was said in that file"
            case .tooLongForModel(let seconds, let limit, let model):
                return String(
                    format: "that file is %@ and %@ takes at most %@ in one request — "
                        + "pick a local model in Settings › Models for long recordings",
                    Self.clock(seconds), model, Self.clock(limit)
                )
            }
        }

        private static func clock(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return total < 60
                ? "\(total)s"
                : String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    let transcriber: Transcriber
    let wordlist: Wordlist
    /// Nil unless the caller asked for cleanup — unlike dictation, where it
    /// follows the setting. See `TranscriptChunker` for why it isn't free here.
    let cleaner: TextCleaner?
    let cleanup: CleanupSettings
    let store: TranscriptStore?
    let languages: [String]
    let transcription: TranscriptionContext
    let modelID: String

    func run(url: URL, progress: @Sendable (Stage) -> Void = { _ in }) async throws -> Outcome {
        let started = Date()
        progress(.decoding)
        // Ahead of the transcription so the duration is known even when the
        // engine streams the file itself and never returns a sample count.
        let seconds = await AudioFileReader.duration(of: url) ?? 0

        progress(.transcribing)
        let raw: String
        do {
            raw = try await transcriber.transcribe(fileAt: url, context: transcription)
        } catch let error as TranscriberError {
            // The API model's own ceiling, restated as the thing to do about it.
            // "recording is 4200s" is a fact about a recording nobody made.
            if case .audioTooLong(let seconds, let limit) = error {
                throw FileError.tooLongForModel(seconds: seconds, limit: limit, model: modelID)
            }
            throw error
        }
        guard !raw.isEmpty else { throw FileError.silence }

        var text = wordlist.apply(to: raw)
        var wasCleaned = false
        if let cleaner {
            let result = await clean(text, with: cleaner, progress: progress)
            text = wordlist.apply(to: result.text)
            wasCleaned = result.cleaned
        }

        let elapsed = Date().timeIntervalSince(started)

        store?.append(TranscriptEntry(
            at: Date(),
            raw: raw,
            text: text,
            model: modelID,
            seconds: seconds,
            latched: false,
            cleaned: wasCleaned,
            mode: .file
        ))
        // Deliberately no `StatsStore` write. Usage answers "how much time did
        // speaking save you against typing", and an hour of audio recorded by
        // someone else would put a day of imaginary saved time in the total.

        return Outcome(
            raw: raw,
            text: text,
            seconds: seconds,
            elapsed: elapsed,
            cleaned: wasCleaned,
            model: modelID
        )
    }

    /// Cleanup, chunked.
    ///
    /// An hour of speech is around ten thousand words, and asking any provider
    /// to repair that in one request is either a context-limit error or a bill.
    /// So the transcript is cut on sentence boundaries into pieces a model can
    /// hold, and each piece goes through the same `cleanWithFallback` dictation
    /// uses — which means one chunk that times out costs its own raw text and
    /// nothing else.
    ///
    /// Sequentially, not in parallel: the providers rate-limit, and the failure
    /// mode of hitting one is every remaining chunk failing at once.
    private func clean(
        _ text: String,
        with cleaner: TextCleaner,
        progress: @Sendable (Stage) -> Void
    ) async -> (text: String, cleaned: Bool) {
        let chunks = TranscriptChunker.chunks(of: text)
        let context = CleanupContext(
            vocabulary: transcription.vocabulary,
            languages: languages
        )
        // A file has no cursor waiting on it. The dictation timeout is tuned for
        // someone staring at a text field, and applying it here would fail every
        // chunk of a long transcript on a slow provider.
        let timeout = max(cleanup.timeoutS, 90)

        var cleanedParts: [String] = []
        var anyCleaned = false
        for (index, chunk) in chunks.enumerated() {
            progress(.cleaning(chunk: index + 1, of: chunks.count))
            let result = await cleanWithFallback(
                chunk,
                cleaner: cleaner,
                context: context,
                timeout: timeout
            )
            cleanedParts.append(result.text)
            anyCleaned = anyCleaned || result.cleaned
        }
        return (cleanedParts.joined(separator: "\n\n"), anyCleaned)
    }
}

/// Cuts a long transcript into pieces small enough to hand a language model.
///
/// Sentence boundaries first, word count only as the backstop: raw ASR output
/// of a monologue can run thousands of words without a full stop, and a chunker
/// that only knew about sentences would hand the model the whole thing anyway.
enum TranscriptChunker {
    /// About 1200 words a chunk. Comfortably inside every provider's window
    /// with the prompt on top, and large enough that an hour-long transcript is
    /// eight or nine requests rather than fifty.
    static let defaultMaxWords = 1200

    static func chunks(of text: String, maxWords: Int = defaultMaxWords) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard wordCount(trimmed) > maxWords else { return [trimmed] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for sentence in sentences(in: trimmed) {
            let words = wordCount(sentence)
            // A single sentence over the budget is split on words rather than
            // sent whole — the runaway monologue case.
            if words > maxWords {
                if !current.isEmpty {
                    chunks.append(current.joined(separator: " "))
                    current = []
                    currentWords = 0
                }
                chunks.append(contentsOf: splitOnWords(sentence, maxWords: maxWords))
                continue
            }
            if currentWords + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    private static func splitOnWords(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return stride(from: 0, to: words.count, by: maxWords).map { start in
            words[start..<min(start + maxWords, words.count)].joined(separator: " ")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
