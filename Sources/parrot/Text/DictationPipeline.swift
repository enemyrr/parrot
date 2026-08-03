import Foundation

/// Everything between "audio stopped" and "text at the cursor":
///
///     transcribe → wordlist → cleanup → wordlist → tag → shortcuts → store → return
///
/// The wordlist runs on both sides on purpose: before, so the cleanup model
/// sees correct proper nouns; after, so the user's replacements win no matter
/// what the model did with them. It's idempotent, so running it twice is free.
///
/// Tagging and shortcuts both run once, at the end, and for the same reason:
/// what they emit is literal text the app has to see character for character —
/// an `@mention`, an address, a whole canned prompt — and nothing downstream of
/// the user should get an opinion about it. Shortcut triggers are additionally
/// fenced off from both wordlist passes, since a rule that respells one leaves a
/// shortcut that quietly never fires. Tags need no such fence: their keys are
/// built from names read off the same screen, so a wordlist rule that respells
/// one has respelled it into a key the table also holds.
struct DictationPipeline {
    let transcriber: Transcriber
    let wordlist: Wordlist
    let shortcuts: ShortcutExpander
    /// Names off the app in front, as literal rewrites. Empty unless
    /// integrations are on and the roster came back usable — see `EntityTagger`.
    let tagger: EntityTagger
    let cleaner: TextCleaner?
    let cleanup: CleanupSettings
    /// The style categories. Only the parts cleanup is allowed to act on reach
    /// the prompt — see `CleanupPrompt.instructions`.
    let style: StyleSettings
    /// Which app the text is headed for, captured when the key went down. The
    /// id only: dictation never reads what is in the window, which is the whole
    /// difference between it and squawk.
    let bundleID: String?
    let store: TranscriptStore?
    /// Passed to the cleaner so it doesn't "correct" one of your
    /// languages into another. Display names, not ISO codes.
    let languages: [String]
    /// Passed to the transcriber. Ignored by a local decoder, which takes no
    /// hints at inference time; the API model uses both halves of it.
    let transcription: TranscriptionContext
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
            raw = try await transcriber.transcribe(samples, context: transcription)
        } catch {
            let detail = (error as? TranscriberError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data("transcription failed: \(detail)\n".utf8))
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        guard !raw.isEmpty else {
            FileHandle.standardError.write(Data(
                String(format: "→ %.2fs · (silence)\n", elapsed).utf8
            ))
            return nil
        }

        // The wordlist runs first and shortcuts run last, so a replacement is
        // free to respell a trigger's words out from under the expander — the
        // one rewriter the triggers weren't fenced from. Find them and hold
        // the wordlist off them, on both passes.
        var text = wordlist.apply(to: raw, excluding: shortcuts.triggerRanges(in: raw))
        var wasCleaned = false

        if let cleaner, shouldClean(text) {
            let result = await cleanWithFallback(
                text,
                cleaner: cleaner,
                context: CleanupContext(
                    // The same list the transcriber got, not a second copy of
                    // the same union: it already carries the trigger phrases,
                    // and a cleaner that "corrects" one of them leaves a
                    // shortcut that no longer fires, which the user only sees
                    // as it quietly stopping working.
                    vocabulary: transcription.vocabulary,
                    languages: languages,
                    category: style.category(for: bundleID)
                ),
                timeout: cleanup.timeoutS
            )
            text = wordlist.apply(
                to: result.text,
                excluding: shortcuts.triggerRanges(in: result.text)
            )
            wasCleaned = result.cleaned
        }

        // Before shortcuts, never after: an expansion is arbitrary text the user
        // wrote, and an address or a canned prompt containing the word "at" is
        // not a mention waiting to happen.
        // Fenced off the triggers for the same reason the wordlist is: a tag
        // that respells a word inside "send my email shortcut" leaves an
        // expansion that quietly stops firing.
        text = tagger.apply(to: text, excluding: shortcuts.triggerRanges(in: text))
        text = shortcuts.apply(to: text)

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
