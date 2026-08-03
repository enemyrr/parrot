import Foundation

/// Turns spoken references into the thing the app in front actually links.
///
///     "post it in hashtag eng parrot"  →  "post it in #eng-parrot"
///     "ask at sara about the deploy"   →  "ask @Sara about the deploy"
///     "look at auth provider"          →  "look @AuthProvider.tsx"
///
/// **Deterministic, and not a model.** The table comes off the screen, the
/// rewrite is a literal phrase match against it, and nothing else can come out
/// the far end. That matters more here than anywhere else in the pipeline: an
/// `@mention` is not a typo, it notifies a real person, and a language model
/// asked to "tag the names" will eventually tag one that was never on screen.
/// It also means this works with cleanup switched off, which is the default —
/// a feature that needed the cleanup model would do nothing for most people.
///
/// Runs late, next to `ShortcutExpander` and for the same reason: what it emits
/// is a literal the app has to see character for character, and nothing
/// downstream should get an opinion about it.
struct EntityTagger {
    private let rules: PhraseRules
    /// The names behind the rules, for the transcriber and the cleaner. Handing
    /// the decoder "eng-parrot" is what makes it come back as "eng parrot"
    /// rather than "ang parrot", which is the difference between the rule
    /// firing and not.
    let vocabulary: [String]
    let entityCount: Int

    static let empty = EntityTagger(roster: nil, settings: .default)

    init(roster: AppRoster?, settings: IntegrationSettings) {
        guard settings.enabled,
            let roster, roster.isUsable,
            let id = roster.integrationID, settings.isEnabled(id)
        else {
            self.rules = PhraseRules([])
            self.vocabulary = []
            self.entityCount = 0
            return
        }

        var pairs: [(key: String, value: String)] = []
        var seenKeys = Set<String>()

        for entity in roster.entities.prefix(settings.maxEntities) {
            for key in Self.keys(for: entity, settings: settings) {
                // A rewrite that changes nothing is a rule that can only ever
                // get in the way of a longer one.
                guard key.lowercased() != entity.literal.lowercased() else { continue }
                guard seenKeys.insert(key).inserted else { continue }
                pairs.append((key: key, value: entity.literal))
            }
        }

        self.rules = PhraseRules(pairs, looseSpacing: true)
        self.vocabulary = settings.learnVocabulary ? roster.vocabulary() : []
        self.entityCount = roster.entities.count
    }

    var isEmpty: Bool { rules.isEmpty }

    /// - Parameter excluding: spans to leave alone, for the same reason the
    ///   wordlist takes them: a tag that respells a shortcut's trigger words
    ///   leaves an expansion that silently stops firing.
    func apply(to text: String, excluding: [NSRange] = []) -> String {
        rules.apply(to: text, excluding: excluding)
    }

    /// Every phrase that should become this entity.
    ///
    /// The trigger word is part of the key and gets consumed by the rewrite —
    /// "hashtag eng parrot" becomes "#eng-parrot", not "hashtag #eng-parrot".
    /// It is also what makes the whole thing safe to run on ordinary dictation:
    /// nothing fires unless the speaker reached for the sigil by name.
    static func keys(for entity: AppEntity, settings: IntegrationSettings) -> [String] {
        guard let triggers = entity.kind.triggers else {
            // Symbols have no trigger. They are a spelling correction — "use
            // effect" was never going to come back as `useEffect` on its own —
            // so the spoken form is the whole key, and it takes its own switch.
            guard settings.spellSymbols else { return [] }
            return entity.spokenForms.filter { form in
                form.split(whereSeparator: \.isWhitespace).count >= 2
            }
        }
        guard settings.tagMentions else { return [] }
        return triggers.flatMap { trigger in
            entity.spokenForms.map { "\(trigger) \($0)" }
        }
    }
}
