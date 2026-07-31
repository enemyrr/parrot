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

enum CleanupProvider: String, Codable, CaseIterable, Identifiable {
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
    var provider: CleanupProvider
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
        provider: CleanupProvider,
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
        provider = try c.decodeIfPresent(CleanupProvider.self, forKey: .provider) ?? d.provider
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

/// How the recording pill visualises your voice.
enum OverlayStyle: String, Codable, CaseIterable, Identifiable {
    /// Scrolling bar meter — newest sample enters right and travels left.
    case bars
    /// Siri-style stroked wave that lies flat when silent.
    case line

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: return "Bars"
        case .line: return "Wave"
        }
    }
}

struct OverlaySettings: Codable, Equatable {
    var enabled: Bool
    var style: OverlayStyle
    /// Meter sensitivity. 1.0 is the default; higher lowers the noise floor so
    /// quieter mics and softer voices still fill the bars.
    ///
    /// Clamped on write rather than only at the boundaries: a slider, a decoded
    /// blob and a direct assignment are three ways in, and a sensitivity of 0
    /// divides by zero in the meter.
    var sensitivity: Double {
        didSet { sensitivity = Self.clampSensitivity(sensitivity) }
    }

    static let `default` = OverlaySettings(enabled: true, style: .bars, sensitivity: 1)

    init(enabled: Bool, style: OverlayStyle, sensitivity: Double) {
        self.enabled = enabled
        self.style = style
        self.sensitivity = Self.clampSensitivity(sensitivity)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        style = try c.decodeIfPresent(OverlayStyle.self, forKey: .style) ?? d.style
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
