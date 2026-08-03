import Foundation

/// How you want to sound, per kind of writing.
///
/// Style used to be one tone and one length for everything, with a list of
/// per-app notes bolted on the side. That is the wrong shape: the tone you want
/// in Mail is not the tone you want in Slack, and a single global tone made the
/// per-app notes carry the whole difference in prose. So the category *is* the
/// setting — a name, the apps it claims, and its own tone, length and notes.
///
/// Each knob says which of the two paths it reaches:
///
/// - **Tone** reaches both dictation and squawk. Cleanup owns punctuation and
///   casing, so a tone can ask it for exclamation marks or for none — but never
///   for different words.
/// - **Length** and **About you** reach squawk only. Cleanup repairs a
///   transcript; it does not get to decide how much you meant to say, or to
///   know who you are.
/// - **Notes** reach both, fenced the same way tone is.
struct StyleSettings: Codable, Equatable {
    /// Ordered as the tabs are. Exactly one is the fallback, and it is last —
    /// see `StyleCategory.isFallback`.
    var categories: [StyleCategory]
    /// Who you are, in your words. Global, because it is the one thing about
    /// your writing that doesn't change with the app you're in. Squawk only,
    /// which is why it is edited on the Squawk pane rather than here.
    var about: String

    static let `default` = StyleSettings(
        categories: StyleCategory.starters,
        about: ""
    )

    init(categories: [StyleCategory], about: String) {
        self.categories = categories
        self.about = about
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StyleSettings.default
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? d.about
        if let stored = try c.decodeIfPresent([StyleCategory].self, forKey: .categories) {
            categories = StyleSettings.normalized(stored)
        } else {
            // A blob from before categories existed: one tone and one length
            // for everything, plus a list of per-app profiles. Every profile
            // becomes a category carrying that same tone and length, so the
            // upgrade changes nothing about how anything is written — it only
            // makes each of them editable on its own from here on.
            let legacy = try LegacyStyleShape(from: decoder)
            categories = StyleSettings.migrating(
                tone: legacy.tone ?? .formal,
                length: legacy.length ?? .natural,
                profiles: legacy.profiles ?? []
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case categories, about
    }

    // MARK: - Matching

    /// The category to write with. Never nil: an app nothing claims is what the
    /// fallback is for, so every call site gets a tone and a length rather than
    /// an optional it has to invent a default for.
    func category(for bundleID: String?) -> StyleCategory {
        guard let bundleID,
            let claimed = categories.first(where: { !$0.isFallback && $0.matches(bundleID) })
        else {
            return fallback
        }
        return claimed
    }

    /// The catch-all. Synthesised if a hand-edited settings file lost it, so
    /// nothing downstream has to cope with its absence.
    var fallback: StyleCategory {
        categories.first(where: \.isFallback) ?? .fallbackStarter
    }

    // MARK: - Invariants

    /// Exactly one fallback, and it sorts last.
    ///
    /// Both are things the UI relies on — the last tab is the one that can't be
    /// deleted — and both are things a decoded blob can violate, either from an
    /// older build or from someone editing the JSON.
    static func normalized(_ categories: [StyleCategory]) -> [StyleCategory] {
        var claimed = categories.filter { !$0.isFallback }
        var fallbacks = categories.filter(\.isFallback)
        // More than one is a file that was edited by hand. Keeping the first
        // and demoting the rest to ordinary categories loses nothing the user
        // wrote, which beats dropping them.
        if fallbacks.count > 1 {
            let extras = fallbacks.dropFirst().map { category -> StyleCategory in
                var demoted = category
                demoted.isFallback = false
                return demoted
            }
            claimed.append(contentsOf: extras)
            fallbacks = [fallbacks[0]]
        }
        return claimed + [fallbacks.first ?? .fallbackStarter]
    }

    /// Legacy profiles, one category each, all sharing the tone and length that
    /// used to be global.
    static func migrating(
        tone: Tone,
        length: Length,
        profiles: [LegacyProfile]
    ) -> [StyleCategory] {
        // Someone who never opened the old pane gets the new starters, not four
        // tabs of the old shipped text. It is the same content either way — but
        // one of them is the current design and the other is a fossil of the
        // previous one, tab bar and all.
        if LegacyProfile.areTheOldShippedDefaults(profiles) {
            return StyleCategory.starters.map { category in
                var carried = category
                carried.tone = tone
                carried.length = length
                return carried
            }
        }
        guard !profiles.isEmpty else {
            var fallback = StyleCategory.fallbackStarter
            fallback.tone = tone
            fallback.length = length
            return [fallback]
        }
        let carried = profiles.map { profile in
            StyleCategory(
                name: profile.name ?? "Apps",
                symbol: StyleCategory.suggestedSymbol(for: profile.name ?? ""),
                bundleIDs: profile.bundleIDs ?? [],
                tone: tone,
                length: length,
                // A profile switched off used to match nothing. There is no
                // off switch any more, so an empty note is how it keeps
                // saying nothing — the apps stay, which is the part that was
                // laborious to enter.
                instructions: (profile.enabled ?? true) ? (profile.instructions ?? "") : ""
            )
        }
        var fallback = StyleCategory.fallbackStarter
        fallback.tone = tone
        fallback.length = length
        return carried + [fallback]
    }
}

// MARK: - Category

/// One kind of writing: the apps it covers, and how to write in them.
///
/// The unit the whole pane is organised around — a tab, with everything about
/// that kind of writing under it. Everything here is per-category on purpose:
/// the point of separating Mail from Slack is that they disagree about tone and
/// length, not only about a paragraph of notes.
struct StyleCategory: Codable, Equatable, Identifiable {
    var id: UUID
    /// The tab's label, and what the model is told it is writing for.
    var name: String
    /// SF Symbol shown in the tab. Cosmetic, and the fastest way to tell four
    /// tabs apart without reading them.
    var symbol: String
    /// Bundle IDs this claims. Matched case-insensitively, with a trailing `*`
    /// allowed so `com.google.Chrome*` catches the helper processes too.
    var bundleIDs: [String]
    var tone: Tone
    var length: Length
    /// The small specific habits: sign-offs, words to avoid, names to keep.
    var instructions: String
    /// The catch-all, for apps no other category claims.
    ///
    /// It has no apps and can't be deleted, because something has to answer
    /// "what tone in an app I never set up?" — and an app-less category that
    /// matched nothing would leave that question with no answer at all.
    var isFallback: Bool

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        bundleIDs: [String],
        tone: Tone = .formal,
        length: Length = .natural,
        instructions: String = "",
        isFallback: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.bundleIDs = bundleIDs
        self.tone = tone
        self.length = length
        self.instructions = instructions
        self.isFallback = isFallback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Apps"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? StyleCategory.defaultSymbol
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        tone = try c.decodeIfPresent(Tone.self, forKey: .tone) ?? .formal
        length = try c.decodeIfPresent(Length.self, forKey: .length) ?? .natural
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        isFallback = try c.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
    }

    func matches(_ bundleID: String) -> Bool {
        BundleIDPattern.matches(any: bundleIDs, bundleID)
    }

    /// What the name is worth saying to a model.
    ///
    /// The fallback is named for the user's benefit — "Other" is a tab, not a
    /// place you write. Telling a model it is writing for Other is worse than
    /// telling it nothing.
    var promptName: String? { isFallback ? nil : name }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Starters

    static let defaultSymbol = "app.badge"

    /// Three kinds of writing and a catch-all.
    ///
    /// Shipped populated, because an empty tab bar makes the feature look like
    /// it does nothing. Three rather than one per app: the thing that actually
    /// changes how you write is who is reading, and email / colleagues /
    /// friends is the whole of that distinction for most people. A tab per app
    /// is a row of tabs to set up before the feature does anything, and every
    /// one of them wanted the same answer as the tab beside it.
    ///
    /// The tones differ between them on purpose: it is the demo.
    static let starters: [StyleCategory] = [
        StyleCategory(
            name: "Email",
            symbol: "envelope",
            bundleIDs: [
                "com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook",
                "com.superhuman.mail",
            ],
            tone: .formal,
            length: .natural,
            instructions: "Full sentences. Keep the greeting and sign off the way the thread "
                + "does. Don't restate the question you're answering."
        ),
        StyleCategory(
            name: "Work messages",
            symbol: "bubble.left.and.bubble.right",
            bundleIDs: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.hnc.Discord"],
            tone: .casual,
            length: .natural,
            instructions: "Short and direct, one paragraph. No greeting. Threads are informal — "
                + "write the way the channel does."
        ),
        StyleCategory(
            name: "Casual messages",
            symbol: "message",
            bundleIDs: ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"],
            tone: .casual,
            length: .direct,
            instructions: "One short message. No greeting, no sign-off, no subject line. "
                + "Match the casing and punctuation of the conversation, including lowercase."
        ),
        .fallbackStarter,
    ]

    /// A fresh catch-all. Not a `let`, because every new `StyleSettings` needs
    /// its own id.
    static var fallbackStarter: StyleCategory {
        StyleCategory(
            name: "Other",
            symbol: "square.grid.2x2",
            bundleIDs: [],
            tone: .formal,
            length: .natural,
            instructions: "",
            isFallback: true
        )
    }

    /// Symbols offered in the picker. A short list on purpose — this is a tab
    /// icon, and a full symbol browser is more decision than the job is worth.
    static let symbolChoices = [
        "envelope", "message", "bubble.left.and.bubble.right", "doc.text", "note.text",
        "terminal", "chevron.left.forwardslash.chevron.right", "globe", "briefcase",
        "person.2", "calendar", "cart", "sparkles", "heart", "square.grid.2x2", "app.badge",
    ]

    /// A guess from the name, for a migrated profile that never had one.
    static func suggestedSymbol(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("mail") || lowered.contains("email") { return "envelope" }
        if lowered.contains("slack") || lowered.contains("discord") || lowered.contains("chat") {
            return "bubble.left.and.bubble.right"
        }
        if lowered.contains("message") || lowered.contains("sms") { return "message" }
        if lowered.contains("note") || lowered.contains("doc") { return "doc.text" }
        if lowered.contains("code") || lowered.contains("term") { return "terminal" }
        return defaultSymbol
    }
}

// MARK: - Legacy

/// The pre-categories shape of `style`, read once on the first load after the
/// upgrade and never written back.
private struct LegacyStyleShape: Decodable {
    let tone: Tone?
    let length: Length?
    let profiles: [LegacyProfile]?
}

/// A pre-categories per-app profile. Also the shape `Settings` digs out of the
/// even older `squawk` object, which is why it isn't private.
struct LegacyProfile: Decodable {
    let name: String?
    let bundleIDs: [String]?
    let instructions: String?
    let enabled: Bool?

    /// True when this is the shipped set, untouched.
    ///
    /// Matched on the instructions as well as the names, so a profile whose
    /// prose someone edited is not mistaken for one they never opened — that
    /// text is theirs and migrates across as a category of its own.
    static func areTheOldShippedDefaults(_ profiles: [LegacyProfile]) -> Bool {
        guard profiles.count == oldShipped.count else { return false }
        return zip(profiles, oldShipped).allSatisfy { profile, shipped in
            profile.name == shipped.name
                && profile.bundleIDs == shipped.bundleIDs
                && profile.instructions == shipped.instructions
                && (profile.enabled ?? true)
        }
    }

    /// The four profiles parrot shipped before categories existed, verbatim.
    /// Only ever compared against — nothing constructs these any more.
    private static let oldShipped: [(name: String, bundleIDs: [String], instructions: String)] = [
        (
            "Mail",
            ["com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook"],
            "Full sentences. Keep the greeting and sign off the way the thread does. Don't "
                + "restate the question you're answering."
        ),
        (
            "Messages & chat",
            ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"],
            "One short message. No greeting, no sign-off, no subject line. Match the casing "
                + "and punctuation of the conversation, including lowercase."
        ),
        (
            "Slack & Discord",
            ["com.tinyspeck.slackmacgap", "com.hnc.Discord"],
            "Short and direct, one paragraph. No greeting. Threads are informal — write the "
                + "way the channel does."
        ),
        (
            "Notes & documents",
            ["com.apple.Notes", "md.obsidian", "com.apple.TextEdit"],
            "Prose or bullets, whichever the document already uses. No greeting and no "
                + "sign-off — this is a document, not a message."
        ),
    ]
}

// MARK: - Tone

/// How it should sound. Applies to cleanup and squawk both.
///
/// Three rather than a slider, because the difference between them is something
/// you recognise on sight and can't estimate in the abstract — which is also
/// why the pane shows the same message written three ways instead of three
/// adjectives.
enum Tone: String, Codable, CaseIterable, Identifiable {
    /// The default, and the one that asks for nothing. There used to be a
    /// stricter tone beside it — no contractions, no exclamation marks — but
    /// two neighbouring cards that differ only in severity is a choice nobody
    /// can make from the samples, which is the whole way this is picked.
    case formal
    case excited
    case casual

    var id: String { rawValue }

    /// Anything unrecognised is the default.
    ///
    /// The default used to be stored as `professional`, next to a separate
    /// `formal`; they are one tone now. Throwing on the old value would fail
    /// the decode of the whole settings file, not of one field.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Tone(rawValue: raw) ?? .formal
    }

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .excited: return "Excited"
        case .casual: return "Casual"
        }
    }

    /// The one-line difference, shown under the name in the picker.
    var blurb: String {
        switch self {
        case .formal: return "Professional (default)"
        case .excited: return "More exclamation marks"
        case .casual: return "Less punctuation"
        }
    }

    /// What cleanup is told.
    ///
    /// Deliberately narrow. Cleanup's contract is that it repairs a transcript
    /// without changing the words, and a tone that asked it to rephrase would
    /// break that — and then trip `CleanupGuard` on the way out. So these only
    /// ever ask for punctuation and casing, which is what cleanup already owns.
    ///
    /// `nil` for the default, so the common case pays nothing.
    var cleanupRule: String? {
        switch self {
        case .formal:
            return nil
        case .excited:
            return "Where the speaker was clearly emphatic, end that sentence with an "
                + "exclamation mark instead of a period. At most one per sentence, and "
                + "never add words to sound enthusiastic."
        case .casual:
            return "Punctuate lightly, the way someone types in a chat: commas and "
                + "periods only, and no semicolons. If the speaker ran two short "
                + "thoughts together, a dash is better than splitting them."
        }
    }

    /// What squawk is told. Free to talk about wording — squawk writes.
    var squawkRule: String? {
        switch self {
        case .formal:
            return nil
        case .excited:
            return "Tone: warm and enthusiastic. Exclamation marks where they land "
                + "naturally, at most one per sentence. Never more than one in a row."
        case .casual:
            return "Tone: casual. Contractions, light punctuation, dashes rather than "
                + "semicolons, and none of the corporate softeners."
        }
    }

    /// The same message, written three ways. Static text, not a model call — the
    /// point is to show the difference instantly and for free.
    var sample: String {
        switch self {
        case .formal:
            return "Hi Mark,\n\nHope you're doing well. I wanted to update you here. "
                + "Let me know your thoughts.\n\nBest,\nAlex"
        case .excited:
            return "Hi Mark,\n\nHope you're doing well! I wanted to update you here. "
                + "Let me know your thoughts!\n\nBest,\nAlex"
        case .casual:
            return "Hi Mark — hope you're doing well. I wanted to update you here, let "
                + "me know your thoughts.\n\nBest,\nAlex"
        }
    }
}

// MARK: - Length

/// How much squawk writes when the instruction doesn't say.
///
/// Cleanup has no say in this: it is repairing something you already said, and
/// its length was decided when you said it.
enum Length: String, Codable, CaseIterable, Identifiable {
    case direct
    case natural
    case thorough

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .natural: return "Natural"
        case .thorough: return "Thorough"
        }
    }

    var blurb: String {
        switch self {
        case .direct: return "Brief and to the point"
        case .natural: return "Default"
        case .thorough: return "Adds key context"
        }
    }

    var squawkRule: String? {
        switch self {
        case .natural:
            return nil
        case .direct:
            return "Length: as short as the answer allows — a sentence or two. Leave out "
                + "anything the reader already knows from the thread."
        case .thorough:
            return "Length: answer, then the one piece of context that saves a follow-up "
                + "— the why, or what happens next. One extra sentence, not a paragraph."
        }
    }

    /// One line, three ways. Same purpose as `Tone.sample`.
    var sample: String {
        switch self {
        case .direct: return "Tuesday at 3 works."
        case .natural: return "Tuesday at 3 works for me — I'll send an invite."
        case .thorough:
            return "Tuesday at 3 works for me. I'll send an invite and attach the doc "
                + "we talked about so you have it beforehand."
        }
    }
}
