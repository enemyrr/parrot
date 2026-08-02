import Foundation

/// Everything between "audio stopped" and "an answer at the cursor":
///
///     transcribe → wordlist → prompt → model → guard → inject
///
/// The screen was already read, back when the key went down — see
/// `DictationController`. By the time this runs it is waiting on the model and
/// nothing else.
struct SquawkPipeline {
    let transcriber: Transcriber
    let wordlist: Wordlist
    let client: LLMClient
    let settings: SquawkSettings
    let store: TranscriptStore?
    let stats: StatsStore?
    let transcription: TranscriptionContext
    /// Display names, not ISO codes. Only a tiebreaker for when the screen
    /// gives the model nothing to read the language off.
    let languages: [String]
    let modelID: String

    struct Output {
        let text: String
        let action: SquawkResponse.Action
        /// What was said, for the log and the history.
        let instruction: String
    }

    /// Returns the text to put on screen, or nil when there was nothing to say
    /// or the model couldn't be reached. Every failure here falls back to doing
    /// nothing — a squawk that goes wrong must never type something arbitrary
    /// into the user's window.
    func process(
        samples: [Float],
        seconds: Double,
        latched: Bool,
        context: ScreenContext?
    ) async -> Output? {
        let started = Date()

        let raw: String
        do {
            raw = try await transcriber.transcribe(samples, context: transcription)
        } catch {
            let detail = (error as? TranscriberError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data("transcription failed: \(detail)\n".utf8))
            return nil
        }

        let instruction = wordlist.apply(to: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            FileHandle.standardError.write(Data("🦜 (silence)\n".utf8))
            return nil
        }

        // With a selection, "make this friendlier" plainly means replace it —
        // so that is what an answer that forgot to say becomes. Without one
        // there is nothing to replace, and insert is the only thing that works.
        let fallback: SquawkResponse.Action =
            (context?.selection?.isEmpty == false) ? .replace : .insert

        let request = LLMRequest(
            system: SquawkPrompt.system(
                settings: settings,
                profile: settings.profile(for: context?.bundleID),
                languages: languages
            ),
            user: SquawkPrompt.user(instruction: instruction, context: context),
            maxOutputTokens: max(512, settings.maxCharacters / 2),
            reasoningEffort: settings.reasoningEffort.rawValue,
            schema: SquawkPrompt.schema
        )

        FileHandle.standardError.write(Data(
            "🦜 \"\(instruction)\" · \(context.map(Self.describe) ?? "no context")\n".utf8
        ))

        let answer: String
        do {
            answer = try await withDeadline(settings.timeoutS) {
                try await client.complete(request)
            }
        } catch {
            let detail = (error as? LLMError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data("  squawk failed — \(detail)\n".utf8))
            return nil
        }

        guard let parsed = SquawkResponse.parse(answer, fallback: fallback) else {
            FileHandle.standardError.write(Data("  squawk returned nothing usable\n".utf8))
            return nil
        }
        let text = SquawkGuard.unwrap(parsed.text)
        guard SquawkGuard.accept(text, maxCharacters: settings.maxCharacters) else {
            FileHandle.standardError.write(Data(
                "  squawk refused or ran away — kept the field as it was\n".utf8
            ))
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(
            String(format: "→ %.2fs · %@ · %d chars\n",
                   elapsed, parsed.action.rawValue, text.count).utf8
        ))

        // The instruction and the answer are kept; what was read off the screen
        // is not, ever. History is a convenience — it should not quietly become
        // a log of everything that has been on screen.
        store?.append(TranscriptEntry(
            at: Date(),
            raw: raw,
            text: text,
            model: "\(modelID) + \(client.name)",
            seconds: seconds,
            latched: latched,
            cleaned: false,
            mode: .squawk
        ))

        stats?.record(
            text: text,
            spokenSeconds: seconds,
            processSeconds: elapsed,
            latched: latched,
            model: modelID
        )

        return Output(text: text, action: parsed.action, instruction: instruction)
    }

    private static func describe(_ context: ScreenContext) -> String {
        var parts = [context.app]
        if context.selection != nil { parts.append("selection") }
        if context.focusedText != nil { parts.append("field") }
        if let window = context.windowText { parts.append("\(window.count) chars") }
        if let skipped = context.skipped { parts.append("skipped: \(skipped.rawValue)") }
        return parts.joined(separator: ", ")
    }
}
