import Foundation

/// Everything between "audio stopped" and "text at the cursor":
///
///     transcribe → wordlist → cleanup → wordlist → store → return
///
/// The wordlist runs on both sides on purpose: before, so the cleanup model
/// sees correct proper nouns; after, so the user's replacements win no matter
/// what the model did with them. It's idempotent, so running it twice is free.
struct DictationPipeline {
    let transcriber: Transcriber
    let wordlist: Wordlist
    let cleaner: TextCleaner?
    let cleanup: CleanupConfig
    let store: TranscriptStore?
    /// Passed to the cleaner so it doesn't "correct" one of your
    /// languages into another. Display names, not ISO codes.
    let languages: [String]
    /// Independent of `store` — stats hold no text, so they keep running for
    /// someone who has turned history off.
    let stats: StatsStore?
    let modelID: String

    /// Returns the text to inject, or nil if transcription failed or produced
    /// nothing (Parakeet returns empty for silence rather than inventing words).
    func process(samples: [Float], seconds: Double, latched: Bool) async -> String? {
        let started = Date()
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples)
        } catch {
            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        guard !raw.isEmpty else {
            FileHandle.standardError.write(Data(
                String(format: "→ %.2fs · (silence)\n", elapsed).utf8
            ))
            return nil
        }

        var text = wordlist.apply(to: raw)
        var wasCleaned = false

        if let cleaner, shouldClean(text) {
            let result = await cleanWithFallback(
                text,
                cleaner: cleaner,
                context: CleanupContext(
                    vocabulary: wordlist.vocabulary,
                    languages: languages
                ),
                timeout: cleanup.timeoutS
            )
            text = wordlist.apply(to: result.text)
            wasCleaned = result.cleaned
        }

        let total = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(
            String(format: "→ %.2fs · %@\n", total, text).utf8
        ))

        store?.append(TranscriptEntry(
            at: Date(),
            raw: raw,
            text: text,
            model: modelID,
            seconds: seconds,
            latched: latched,
            cleaned: wasCleaned
        ))

        stats?.record(
            text: text,
            spokenSeconds: seconds,
            processSeconds: total,
            latched: latched,
            model: modelID
        )

        return text
    }

    /// Below a few words the round trip costs more than it's worth — "yes" and
    /// "open the door" don't need punctuation repair.
    private func shouldClean(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= cleanup.minWords
    }
}
