import Foundation

/// Phrases you say on purpose, and the text they become.
///
/// The dictionary's replacements and this look alike and are not the same
/// thing. A replacement repairs a word the transcriber heard wrong; you never
/// meant to say "vercell". A shortcut is deliberate — you say "my email
/// shortcut" precisely so you don't have to spell an address out loud. Three
/// consequences follow from that, and they are why this isn't just more rows in
/// the wordlist:
///
/// - The expansion can be a paragraph, not a word.
/// - Triggers are matched loosely enough to survive whatever punctuation the
///   transcriber sprinkles through them.
/// - It runs **once**, at the end of the pipeline. An email address or a canned
///   prompt is never handed back to the cleanup model to be "corrected", and no
///   wordlist rule gets a second look at what was expanded.
struct ShortcutExpander {
    /// The trigger phrases, for the vocabulary hints upstream. The transcriber
    /// has to hear the trigger correctly and the cleaner has to leave it alone
    /// — a trigger that got rewritten is a trigger that never fires.
    let triggers: [String]
    private let rules: PhraseRules

    init(shortcuts: [TextShortcut]) {
        // First trigger wins a duplicate, matching the order shown in settings.
        var seen = Set<String>()
        var usable: [(trigger: String, expansion: String)] = []
        for shortcut in shortcuts {
            guard let pair = shortcut.usable, seen.insert(pair.trigger.lowercased()).inserted else {
                continue
            }
            usable.append(pair)
        }

        self.triggers = usable.map(\.trigger)
        self.rules = PhraseRules(
            usable.map { (key: $0.trigger, value: $0.expansion) },
            looseSpacing: true
        )
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Where the triggers sit in this text, so the wordlist can be kept off
    /// them. It runs first and would otherwise be free to respell a trigger's
    /// words — "java script" → "JavaScript" — leaving a phrase this no longer
    /// recognises and a shortcut that silently stops firing.
    func triggerRanges(in text: String) -> [NSRange] {
        rules.ranges(in: text)
    }

    func apply(to text: String) -> String {
        rules.apply(to: text)
    }
}
