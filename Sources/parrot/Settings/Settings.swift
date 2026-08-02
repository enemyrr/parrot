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
    var hotkey: Hotkey
    var latch: LatchSettings
    var squawk: SquawkSettings
    var cleanup: CleanupSettings
    var wordlist: WordlistSettings
    var history: HistorySettings
    var stats: StatsSettings
    var overlay: OverlaySettings

    static let `default` = Settings(
        model: ModelRegistry.recommended()?.id ?? "parakeet-v3",
        languages: [],
        hotkey: .fn,
        latch: .default,
        squawk: .default,
        cleanup: .default,
        wordlist: .default,
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
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey
        latch = try c.decodeIfPresent(LatchSettings.self, forKey: .latch) ?? d.latch
        squawk = try c.decodeIfPresent(SquawkSettings.self, forKey: .squawk) ?? d.squawk
        cleanup = try c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? d.cleanup
        wordlist = try c.decodeIfPresent(WordlistSettings.self, forKey: .wordlist) ?? d.wordlist
        history = try c.decodeIfPresent(HistorySettings.self, forKey: .history) ?? d.history
        stats = try c.decodeIfPresent(StatsSettings.self, forKey: .stats) ?? d.stats
        overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? d.overlay
    }

    init(
        model: String,
        languages: [String],
        hotkey: Hotkey,
        latch: LatchSettings,
        squawk: SquawkSettings,
        cleanup: CleanupSettings,
        wordlist: WordlistSettings,
        history: HistorySettings,
        stats: StatsSettings,
        overlay: OverlaySettings
    ) {
        self.model = model
        self.languages = languages
        self.hotkey = hotkey
        self.latch = latch
        self.squawk = squawk
        self.cleanup = cleanup
        self.wordlist = wordlist
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

// MARK: - Sections

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
    var prompt: String
    /// Who you are, in your words. Injected into every squawk.
    var about: String
    /// Per-app instructions, first match wins.
    var profiles: [AppProfile]
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
        about: "",
        profiles: AppProfile.starters,
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
        about: String,
        profiles: [AppProfile],
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
        self.about = about
        self.profiles = profiles
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
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? d.about
        profiles = try c.decodeIfPresent([AppProfile].self, forKey: .profiles) ?? d.profiles
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)
            ?? d.excludedBundleIDs
        context = try c.decodeIfPresent(ContextSettings.self, forKey: .context) ?? d.context
    }

    /// The profile for a bundle ID, if one claims it.
    func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.enabled && $0.matches(bundleID) }
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Two hotkeys that are the same key can't be told apart, and the monitor
    /// would hand every press to whichever binding it looked at first. Checked
    /// here rather than in the pane so the daemon refuses it too.
    func isUsable(alongside dictation: Hotkey) -> Bool {
        hotkey.isUsable && hotkey != dictation
    }
}

/// How an app should be written for.
///
/// The same instruction produces a very different right answer in Mail and in
/// Messages, and neither the model nor a global prompt can know which one you
/// are in. This is the smallest thing that fixes it.
struct AppProfile: Codable, Equatable, Identifiable {
    var id: UUID
    /// Shown in the settings list, and named to the model as the thing it is
    /// writing for.
    var name: String
    /// Bundle IDs this claims. Matched case-insensitively, with a trailing `*`
    /// allowed so `com.google.Chrome*` catches the helper processes too.
    var bundleIDs: [String]
    var instructions: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        bundleIDs: [String],
        instructions: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.instructions = instructions
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "App"
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func matches(_ bundleID: String) -> Bool {
        bundleIDs.contains { pattern in
            guard pattern.hasSuffix("*") else {
                return pattern.caseInsensitiveCompare(bundleID) == .orderedSame
            }
            let prefix = String(pattern.dropLast())
            return bundleID.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    /// Shipped switched on, because an empty profile list makes squawk look
    /// like it ignores the app it is in — and these four are where the
    /// difference is most obvious.
    static let starters: [AppProfile] = [
        AppProfile(
            name: "Mail",
            bundleIDs: ["com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook"],
            instructions: "Full sentences. Keep the greeting and sign off the way the thread "
                + "does. Don't restate the question you're answering."
        ),
        AppProfile(
            name: "Messages & chat",
            bundleIDs: [
                "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
            ],
            instructions: "One short message. No greeting, no sign-off, no subject line. "
                + "Match the casing and punctuation of the conversation, including lowercase."
        ),
        AppProfile(
            name: "Slack & Discord",
            bundleIDs: ["com.tinyspeck.slackmacgap", "com.hnc.Discord"],
            instructions: "Short and direct, one paragraph. No greeting. Threads are informal — "
                + "write the way the channel does."
        ),
        AppProfile(
            name: "Notes & documents",
            bundleIDs: ["com.apple.Notes", "md.obsidian", "com.apple.TextEdit"],
            instructions: "Prose or bullets, whichever the document already uses. No greeting "
                + "and no sign-off — this is a document, not a message."
        ),
    ]
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
        for rule in replacements where !rule.from.trimmingCharacters(in: .whitespaces).isEmpty {
            map[rule.from] = rule.to
        }
        return map
    }
}

/// The pill.
///
/// It used to carry a `style` the user picked. It no longer does: the
/// visualiser is how you tell dictation from squawk at a glance, so it belongs
/// to the mode rather than to taste. A stored `style` from an older build
/// decodes to nothing and is dropped on the next write.
struct OverlaySettings: Codable, Equatable {
    var enabled: Bool
    /// Meter sensitivity. 1.0 is the default; higher lowers the noise floor so
    /// quieter mics and softer voices still fill the bars.
    ///
    /// Clamped on write rather than only at the boundaries: a slider, a decoded
    /// blob and a direct assignment are three ways in, and a sensitivity of 0
    /// divides by zero in the meter.
    var sensitivity: Double {
        didSet { sensitivity = Self.clampSensitivity(sensitivity) }
    }

    static let `default` = OverlaySettings(enabled: true, sensitivity: 1)

    init(enabled: Bool, sensitivity: Double) {
        self.enabled = enabled
        self.sensitivity = Self.clampSensitivity(sensitivity)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
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
