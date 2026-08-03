import Foundation

/// Literal find → replace over a transcript, plus the vocabulary terms handed
/// to the cleanup model.
///
/// This is the *correction* half of the dictionary: words the transcriber keeps
/// getting wrong, and the spelling that fixes them. A phrase you say on purpose
/// to stand in for something longer is a different thing — see
/// `ShortcutExpander`.
///
/// See `PhraseRules` for how the matching works.
struct Wordlist {
    private let rules: PhraseRules
    let vocabulary: [String]

    init(settings: WordlistSettings) {
        self.vocabulary = settings.vocabulary
        self.rules = PhraseRules(settings.replacementMap.map { ($0.key, $0.value) })
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Apply every rule in one pass.
    ///
    /// Idempotent for well-formed wordlists — one where no replacement value
    /// re-introduces another rule's key. Correcting a misspelling to its proper
    /// form (`"vercell"` → `"Vercel"`) or fixing casing (`"claude code"` →
    /// `"Claude Code"`) both satisfy that, which is what lets the pipeline run
    /// this on both sides of the cleanup pass.
    ///
    /// - Parameter excluding: spans no rule may touch. The pipeline passes the
    ///   shortcut triggers it found, which are said on purpose and are not
    ///   misspellings to be corrected.
    func apply(to text: String, excluding: [NSRange] = []) -> String {
        rules.apply(to: text, excluding: excluding)
    }
}
