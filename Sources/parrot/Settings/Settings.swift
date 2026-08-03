import Foundation

/// Everything the user can change, in one value type.
///
/// This replaced a hand-edited `config.toml`. Being one `Codable` struct rather
/// than a tree of preference keys buys three things the settings window leans
/// on: it round-trips through `UserDefaults` as a single atomic blob, it is
/// `Equatable` so the daemon can diff old against new and reconfigure only what
/// actually changed, and a value absent from the stored JSON simply takes its
/// default — so a settings file written by an older build still loads.
struct Settings: Codable, Equatable {
    var model: String
    /// Languages you actually speak, as ISO codes. Empty means no constraint.
    /// See `LanguageSelection` for what this does and does not do.
    var languages: [String]
    /// Which microphone to record from. See `AudioSettings`.
    var audio: AudioSettings
    var hotkey: Hotkey
    var latch: LatchSettings
    var squawk: SquawkSettings
    /// How you sound, shared by both paths. See `StyleSettings` — it used to
    /// live inside `squawk`, which is why decoding has a migration for it.
    var style: StyleSettings
    var cleanup: CleanupSettings
    var wordlist: WordlistSettings
    /// Phrases you say on purpose. Kept apart from `wordlist` because they are
    /// a different thing that happens to be implemented the same way — see
    /// `ShortcutExpander`.
    var shortcuts: [TextShortcut]
    /// Names read off the app you're dictating into. See `IntegrationSettings`
    /// — this is the one thing that lets dictation look at a window at all.
    var integrations: IntegrationSettings
    var history: HistorySettings
    var stats: StatsSettings
    var overlay: OverlaySettings

    static let `default` = Settings(
        model: ModelRegistry.recommended()?.id ?? "parakeet-v3",
        languages: [],
        audio: .default,
        hotkey: .fn,
        latch: .default,
        squawk: .default,
        style: .default,
        cleanup: .default,
        wordlist: .default,
        shortcuts: [],
        integrations: .default,
        history: .default,
        stats: .default,
        overlay: .default
    )

    /// Decoding tolerates a missing key everywhere. A settings blob written by
    /// an older build gains the new field's default rather than failing to load
    /// and silently resetting everything the user had configured.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? d.languages
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? d.audio
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey
        latch = try c.decodeIfPresent(LatchSettings.self, forKey: .latch) ?? d.latch
        squawk = try c.decodeIfPresent(SquawkSettings.self, forKey: .squawk) ?? d.squawk
        // "About you" and the per-app profiles used to be squawk's alone. A blob
        // written before they moved has no `style` key at all, and reading them
        // back out of `squawk` is the difference between an upgrade that keeps
        // what someone wrote and one that silently resets it.
        if let stored = try c.decodeIfPresent(StyleSettings.self, forKey: .style) {
            style = stored
        } else if let legacy = try c.decodeIfPresent(LegacyStyle.self, forKey: .squawk),
            legacy.about != nil || legacy.profiles != nil
        {
            style = StyleSettings(
                // Only a blob that actually carried profiles gets them turned
                // into categories. One that never had the key keeps the
                // starters, rather than being migrated down to a single
                // catch-all because it had nothing to migrate.
                categories: legacy.profiles.map {
                    StyleSettings.migrating(tone: .formal, length: .natural, profiles: $0)
                } ?? d.style.categories,
                about: legacy.about ?? d.style.about
            )
        } else {
            style = d.style
        }
        cleanup = try c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? d.cleanup
        wordlist = try c.decodeIfPresent(WordlistSettings.self, forKey: .wordlist) ?? d.wordlist
        shortcuts = try c.decodeIfPresent([TextShortcut].self, forKey: .shortcuts) ?? d.shortcuts
        integrations = try c.decodeIfPresent(IntegrationSettings.self, forKey: .integrations)
            ?? d.integrations
        history = try c.decodeIfPresent(HistorySettings.self, forKey: .history) ?? d.history
        stats = try c.decodeIfPresent(StatsSettings.self, forKey: .stats) ?? d.stats
        overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? d.overlay
    }

    init(
        model: String,
        languages: [String],
        audio: AudioSettings,
        hotkey: Hotkey,
        latch: LatchSettings,
        squawk: SquawkSettings,
        style: StyleSettings,
        cleanup: CleanupSettings,
        wordlist: WordlistSettings,
        shortcuts: [TextShortcut],
        integrations: IntegrationSettings,
        history: HistorySettings,
        stats: StatsSettings,
        overlay: OverlaySettings
    ) {
        self.model = model
        self.languages = languages
        self.audio = audio
        self.hotkey = hotkey
        self.latch = latch
        self.squawk = squawk
        self.style = style
        self.cleanup = cleanup
        self.wordlist = wordlist
        self.shortcuts = shortcuts
        self.integrations = integrations
        self.history = history
        self.stats = stats
        self.overlay = overlay
    }

    /// The model to actually load. A settings blob can name a model that has
    /// since been retired or renamed, and refusing to start over it would be a
    /// worse answer than falling back to the recommended one.
    var resolvedModel: TranscriptionModel {
        ModelRegistry.find(model)
            ?? ModelRegistry.recommended()
            ?? ModelRegistry.shared[0]
    }
}

/// The two fields that moved out of `squawk` and into `style`.
///
/// Both are gone from `SquawkSettings`, so nothing decodes them any more — this
/// reads the old shape out of the same JSON object one time, on the first load
/// after the upgrade, and is never written back.
private struct LegacyStyle: Decodable {
    let about: String?
    let profiles: [LegacyProfile]?
}

// MARK: - Sections

/// Which microphone recordings come from, and what happens to everything else
/// coming out of the Mac while one is in progress.
///
/// The device is stored as a CoreAudio UID rather than a device id, because the
/// id is assigned per boot and would name a different device — or nothing — the
/// next morning. An empty UID means "whatever macOS is using", which is both the
/// default and what the menu ticks until someone chooses otherwise.
struct AudioSettings: Codable, Equatable {
    var inputDeviceUID: String
    /// Silence the Mac's output for the length of a recording. Off by default:
    /// reaching into the system volume is not something dictation should start
    /// doing to someone who never asked for it. See `SystemAudioMute`.
    var muteWhileDictating: Bool

    static let `default` = AudioSettings(inputDeviceUID: "", muteWhileDictating: false)

    init(inputDeviceUID: String, muteWhileDictating: Bool) {
        self.inputDeviceUID = inputDeviceUID
        self.muteWhileDictating = muteWhileDictating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioSettings.default
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
            ?? d.inputDeviceUID
        muteWhileDictating = try c.decodeIfPresent(Bool.self, forKey: .muteWhileDictating)
            ?? d.muteWhileDictating
    }
}

struct LatchSettings: Codable, Equatable {
    /// Double-tapping the hotkey keeps recording without holding it.
    var enabled: Bool
    /// A hold shorter than this counts as a tap rather than push-to-talk.
    var tapMs: Int
    /// The second tap must land within this window of the first release.
    var windowMs: Int
    /// Hands-free recordings stop and transcribe after this long.
    var maxSeconds: Int

    static let `default` = LatchSettings(enabled: true, tapMs: 300, windowMs: 300, maxSeconds: 300)

    init(enabled: Bool, tapMs: Int, windowMs: Int, maxSeconds: Int) {
        self.enabled = enabled
        self.tapMs = tapMs
        self.windowMs = windowMs
        self.maxSeconds = maxSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LatchSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        tapMs = try c.decodeIfPresent(Int.self, forKey: .tapMs) ?? d.tapMs
        windowMs = try c.decodeIfPresent(Int.self, forKey: .windowMs) ?? d.windowMs
        maxSeconds = try c.decodeIfPresent(Int.self, forKey: .maxSeconds) ?? d.maxSeconds
    }
}

/// What a recording is *for*. Chosen by which hotkey started it, and carried
/// all the way through to the pill so the two are never mistaken for each other.
enum DictationMode: String, Codable, Equatable, CaseIterable {
    /// Speech becomes text, verbatim. The original parrot.
    case dictate
    /// Speech is an instruction. What lands at the cursor is a model's answer,
    /// written against what's on screen.
    case squawk

    var displayName: String {
        switch self {
        case .dictate: return "Dictation"
        case .squawk: return "Squawk"
        }
    }
}

/// The second hotkey, and what it does.
///
/// Off by default, and deliberately so: squawk is the one path that reads the
/// screen. Nothing about it runs — no context capture, no second key registered
/// — until someone turns it on.
struct SquawkSettings: Codable, Equatable {
    var enabled: Bool
    /// Held or double-tapped exactly like the dictation key. Must resolve to
    /// something other than `Settings.hotkey`; see `isUsable(alongside:)`.
    var hotkey: Hotkey
    /// Independent of the cleanup provider on purpose: cleanup wants something
    /// fast and cheap that fixes punctuation, squawk wants something that can
    /// write. They are rarely the same model.
    var provider: LLMProvider
    /// Empty means the provider's own default.
    var model: String
    var reasoningEffort: ReasoningEffort
    /// Longer than cleanup's, because this one writes rather than repairs.
    var timeoutS: Double
    /// A runaway answer becomes a runaway paste. Characters, not tokens —
    /// what matters is how much text lands in the field.
    var maxCharacters: Int
    /// Empty means the built-in base prompt.
    ///
    /// Who you are and how each app should be written for are *not* here — they
    /// are in `StyleSettings`, because dictation needs them too.
    var prompt: String
    /// Bundle IDs never read from, on top of the ones that are always excluded.
    var excludedBundleIDs: [String]
    var context: ContextSettings

    static let `default` = SquawkSettings(
        enabled: false,
        hotkey: .control,
        // Matches the cleanup default, and for the same reason: on-device means
        // the screen contents never leave the Mac. It is the weakest writer of
        // the three, and it is the only one that needs no key and no decision.
        provider: .apple,
        model: "",
        reasoningEffort: .unset,
        timeoutS: 25,
        maxCharacters: 4000,
        prompt: "",
        excludedBundleIDs: [],
        context: .default
    )

    init(
        enabled: Bool,
        hotkey: Hotkey,
        provider: LLMProvider,
        model: String,
        reasoningEffort: ReasoningEffort,
        timeoutS: Double,
        maxCharacters: Int,
        prompt: String,
        excludedBundleIDs: [String],
        context: ContextSettings
    ) {
        self.enabled = enabled
        self.hotkey = hotkey
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.timeoutS = timeoutS
        self.maxCharacters = maxCharacters
        self.prompt = prompt
        self.excludedBundleIDs = excludedBundleIDs
        self.context = context
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SquawkSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey
        provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
            ?? d.reasoningEffort
        timeoutS = try c.decodeIfPresent(Double.self, forKey: .timeoutS) ?? d.timeoutS
        maxCharacters = try c.decodeIfPresent(Int.self, forKey: .maxCharacters) ?? d.maxCharacters
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)
            ?? d.excludedBundleIDs
        context = try c.decodeIfPresent(ContextSettings.self, forKey: .context) ?? d.context
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return BundleIDPattern.matches(any: excludedBundleIDs, bundleID)
    }

    /// Two hotkeys that are the same key can't be told apart, and the monitor
    /// would hand every press to whichever binding it looked at first. Checked
    /// here rather than in the pane so the daemon refuses it too.
    func isUsable(alongside dictation: Hotkey) -> Bool {
        hotkey.isUsable && hotkey != dictation
    }
}

/// Bundle id matching, with the one wildcard the settings file allows: a
/// trailing `*`, so `com.google.Chrome*` claims the helper processes too.
///
/// Shared, because a pattern typed into a style profile and the same pattern
/// typed into the never-read list have to mean the same thing — an exclusion
/// that quietly refuses the wildcard is an exclusion that doesn't hold.
enum BundleIDPattern {
    static func matches(_ pattern: String, _ bundleID: String) -> Bool {
        guard pattern.hasSuffix("*") else {
            return pattern.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        let prefix = String(pattern.dropLast())
        return bundleID.lowercased().hasPrefix(prefix.lowercased())
    }

    static func matches(any patterns: [String], _ bundleID: String) -> Bool {
        patterns.contains { matches($0, bundleID) }
    }
}

/// How much of the screen squawk is allowed to read.
struct ContextSettings: Codable, Equatable {
    /// Read the whole window, not just the selection and the focused field.
    /// The thing that makes "answer this email" work without selecting it
    /// first — and the thing to turn off if that is more than you want sent.
    var readWindow: Bool
    var maxCharacters: Int
    /// Ask Chromium apps to build an accessibility tree. Off means browsers and
    /// Electron apps return nothing; on has a known side effect with window
    /// managers. See `ScreenReader`.
    var enhanceChromium: Bool

    static let `default` = ContextSettings(
        readWindow: true,
        maxCharacters: 6000,
        enhanceChromium: true
    )

    init(readWindow: Bool, maxCharacters: Int, enhanceChromium: Bool) {
        self.readWindow = readWindow
        self.maxCharacters = maxCharacters
        self.enhanceChromium = enhanceChromium
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContextSettings.default
        readWindow = try c.decodeIfPresent(Bool.self, forKey: .readWindow) ?? d.readWindow
        maxCharacters = try c.decodeIfPresent(Int.self, forKey: .maxCharacters) ?? d.maxCharacters
        enhanceChromium = try c.decodeIfPresent(Bool.self, forKey: .enhanceChromium)
            ?? d.enhanceChromium
    }

    var limits: ScreenReader.Limits {
        var limits = ScreenReader.Limits.default
        limits.maxCharacters = maxCharacters
        limits.enhanceChromium = enhanceChromium
        return limits
    }
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case apple
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var blurb: String {
        switch self {
        case .apple: return "On-device. No key, no network, no cost. Needs macOS 26."
        case .anthropic: return "Claude, over the API. Needs a key."
        case .openai: return "GPT, over the API. Needs a key."
        }
    }

    /// Nil for providers that run locally.
    var keychainAccount: Keychain.Account? {
        switch self {
        case .apple: return nil
        case .anthropic: return .anthropic
        case .openai: return .openai
        }
    }

    /// What an empty `model` resolves to, shown as the field's placeholder.
    var defaultModel: String? {
        switch self {
        case .apple: return nil
        case .anthropic: return AnthropicCleaner.defaultModel
        case .openai: return OpenAICleaner.defaultModel
        }
    }
}

/// OpenAI's reasoning-effort knob. Modelled as an enum with an "unset" case so
/// the parameter can be omitted entirely — a non-reasoning model rejects it.
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case unset = ""
    case minimal
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        self == .unset ? "Not set" : rawValue.capitalized
    }
}

struct CleanupSettings: Codable, Equatable {
    var enabled: Bool
    var provider: LLMProvider
    /// API providers only; ignored by the on-device provider. Empty means the
    /// provider's own default so switching providers never sends the wrong
    /// vendor's model name.
    var model: String
    var reasoningEffort: ReasoningEffort
    /// Below this word count, skip cleanup — the latency isn't worth it.
    var minWords: Int
    var timeoutS: Double
    /// Empty means the built-in prompt.
    var prompt: String

    static let `default` = CleanupSettings(
        enabled: false,
        provider: .apple,
        model: "",
        reasoningEffort: .unset,
        minWords: 4,
        timeoutS: 3.0,
        prompt: ""
    )

    init(
        enabled: Bool,
        provider: LLMProvider,
        model: String,
        reasoningEffort: ReasoningEffort,
        minWords: Int,
        timeoutS: Double,
        prompt: String
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.minWords = minWords
        self.timeoutS = timeoutS
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanupSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
            ?? d.reasoningEffort
        minWords = try c.decodeIfPresent(Int.self, forKey: .minWords) ?? d.minWords
        timeoutS = try c.decodeIfPresent(Double.self, forKey: .timeoutS) ?? d.timeoutS
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
    }
}

/// One find → replace rule. Carries an id so SwiftUI can keep a stable row
/// identity while the user is still typing the term — a dictionary keyed by
/// text would reshuffle on every keystroke.
struct Replacement: Codable, Equatable, Identifiable {
    var id: UUID
    var from: String
    var to: String

    init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// A phrase you say on purpose, and the text it turns into.
///
/// Deliberately not a `Replacement`. A replacement fixes a word the transcriber
/// got wrong; this is a trigger for something you'd rather not say out loud in
/// full — an address, a canned prompt, a signature. See `ShortcutExpander` for
/// what falls out of that difference.
struct TextShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    /// What you say. Matched case-insensitively, whole words only, and tolerant
    /// of the punctuation the transcriber puts between the words.
    var trigger: String
    /// What lands at the cursor. May be several lines.
    var expansion: String

    init(id: UUID = UUID(), trigger: String = "", expansion: String = "") {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        expansion = try c.decodeIfPresent(String.self, forKey: .expansion) ?? ""
    }

    /// Trimmed, or nil if either half is still blank. Half-typed rows are
    /// dropped here rather than in the UI, so a shortcut can sit in the list
    /// while you're writing it without firing on the next thing you say.
    var usable: (trigger: String, expansion: String)? {
        let trigger = self.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = self.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return nil }
        return (trigger, expansion)
    }
}

struct WordlistSettings: Codable, Equatable {
    /// Terms the cleanup model is told to preserve verbatim.
    var vocabulary: [String]
    /// Literal find → replace pairs applied to every transcript.
    var replacements: [Replacement]

    static let `default` = WordlistSettings(vocabulary: [], replacements: [])

    init(vocabulary: [String], replacements: [Replacement]) {
        self.vocabulary = vocabulary
        self.replacements = replacements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WordlistSettings.default
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements)
            ?? d.replacements
    }

    /// The form `Wordlist` wants. Blank rows are dropped here rather than in the
    /// UI, so a half-typed rule can sit in the table without taking effect.
    var replacementMap: [String: String] {
        var map: [String: String] = [:]
        for rule in replacements {
            // Trimmed, not just checked: a key with a trailing space compiles
            // to a pattern that demands one, so the rule would fire mid-sentence
            // and silently not before a full stop.
            let from = rule.from.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            map[from] = rule.to
        }
        return map
    }
}

/// Names read off the app you're dictating into, and what is done with them.
///
/// **Off by default, and that is not timidity.** Everywhere else in parrot,
/// dictation reads exactly one thing about the app in front — its bundle id —
/// and squawk is the path that reads windows. This crosses that line, so it is
/// something the user turns on rather than something they discover has been
/// happening. What crosses it is narrow: `RosterReader` collects short labels
/// and their positions and throws the prose away, so what is held is a list of
/// channel names and filenames, never a message. None of it is written to
/// history, and none of it is sent anywhere unless `learnVocabulary` is on and
/// a remote transcriber or cleaner is configured — in which case the names go,
/// as hints, and still not the contents.
struct IntegrationSettings: Codable, Equatable {
    /// The master switch. Nothing walks a window until this is on.
    var enabled: Bool
    /// Integration ids explicitly switched off. An opt-out list rather than an
    /// opt-in one, so an app added in a later build works without anyone having
    /// to go and find the new row.
    var disabledIDs: [String]
    /// "at Sara" → "@Sara", "hashtag eng parrot" → "#eng-parrot".
    var tagMentions: Bool
    /// "use effect" → `useEffect`. Separate from `tagMentions` because it is the
    /// one rewrite with no trigger word in front of it, and so the one most
    /// likely to fire on a sentence that meant the English words.
    var spellSymbols: Bool
    /// Hand the names to the transcriber and the cleaner as hints. This is what
    /// makes the tagging land — a rule for "eng parrot" never fires if the
    /// decoder wrote "ang parrot".
    var learnVocabulary: Bool
    /// Ceiling on the roster. A guard against an app that publishes thousands of
    /// short labels turning into thousands of rewrite rules.
    var maxEntities: Int

    static let `default` = IntegrationSettings(
        enabled: false,
        disabledIDs: [],
        tagMentions: true,
        spellSymbols: true,
        learnVocabulary: true,
        maxEntities: 200
    )

    init(
        enabled: Bool,
        disabledIDs: [String],
        tagMentions: Bool,
        spellSymbols: Bool,
        learnVocabulary: Bool,
        maxEntities: Int
    ) {
        self.enabled = enabled
        self.disabledIDs = disabledIDs
        self.tagMentions = tagMentions
        self.spellSymbols = spellSymbols
        self.learnVocabulary = learnVocabulary
        self.maxEntities = max(1, maxEntities)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntegrationSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        disabledIDs = try c.decodeIfPresent([String].self, forKey: .disabledIDs) ?? d.disabledIDs
        tagMentions = try c.decodeIfPresent(Bool.self, forKey: .tagMentions) ?? d.tagMentions
        spellSymbols = try c.decodeIfPresent(Bool.self, forKey: .spellSymbols) ?? d.spellSymbols
        learnVocabulary = try c.decodeIfPresent(Bool.self, forKey: .learnVocabulary)
            ?? d.learnVocabulary
        maxEntities = max(1, try c.decodeIfPresent(Int.self, forKey: .maxEntities) ?? d.maxEntities)
    }

    func isEnabled(_ integrationID: String) -> Bool {
        !disabledIDs.contains(integrationID)
    }

    mutating func setEnabled(_ isOn: Bool, for integrationID: String) {
        if isOn {
            disabledIDs.removeAll { $0 == integrationID }
        } else if !disabledIDs.contains(integrationID) {
            disabledIDs.append(integrationID)
        }
    }

    /// Whether anything would happen for this app if it were read. An
    /// integration with every rewrite switched off is one that still costs a
    /// walk and produces nothing — worth not doing.
    var doesAnything: Bool {
        enabled && (tagMentions || spellSymbols || learnVocabulary)
    }
}

/// The pill.
///
/// It used to carry a `style` and an `enabled` the user picked. It no longer
/// does: the visualiser is how you tell dictation from squawk at a glance, so
/// it belongs to the mode rather than to taste, and knowing the mic is hot is
/// not optional. Both decode to nothing and are dropped on the next write.
/// `--no-overlay` remains for the one run where the pill is in the way.
struct OverlaySettings: Codable, Equatable {
    /// Meter sensitivity. 1.0 is the default; higher lowers the noise floor so
    /// quieter mics and softer voices still fill the bars.
    ///
    /// Clamped on write rather than only at the boundaries: a slider, a decoded
    /// blob and a direct assignment are three ways in, and a sensitivity of 0
    /// divides by zero in the meter.
    var sensitivity: Double {
        didSet { sensitivity = Self.clampSensitivity(sensitivity) }
    }

    static let `default` = OverlaySettings(sensitivity: 1)

    init(sensitivity: Double) {
        self.sensitivity = Self.clampSensitivity(sensitivity)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings.default
        let raw = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        sensitivity = Self.clampSensitivity(raw)
    }

    static func clampSensitivity(_ value: Double) -> Double {
        min(3, max(0.25, value))
    }
}

struct HistorySettings: Codable, Equatable {
    var enabled: Bool
    var maxEntries: Int

    static let `default` = HistorySettings(enabled: true, maxEntries: 5000)

    init(enabled: Bool, maxEntries: Int) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HistorySettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? d.maxEntries
    }
}

struct StatsSettings: Codable, Equatable {
    var enabled: Bool
    /// The typing speed "time saved" is measured against. An assumption, not a
    /// measurement — surfaced next to the number rather than hidden behind it.
    /// Clamped on write so a stray value can't divide by zero or claim a decade
    /// saved.
    var typingWpm: Double {
        didSet { typingWpm = Self.clampWpm(typingWpm) }
    }

    static let `default` = StatsSettings(enabled: true, typingWpm: 40)

    init(enabled: Bool, typingWpm: Double) {
        self.enabled = enabled
        // Clamped so a typo can't divide by zero or claim a decade saved.
        self.typingWpm = Self.clampWpm(typingWpm)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StatsSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        let raw = try c.decodeIfPresent(Double.self, forKey: .typingWpm) ?? d.typingWpm
        typingWpm = Self.clampWpm(raw)
    }

    static func clampWpm(_ value: Double) -> Double {
        min(200, max(10, value))
    }
}
