import Foundation
import TOMLDecoder

/// User settings from `~/.config/parrot/config.toml`.
///
/// Every field has a default, so a missing file is fine. A file that exists
/// but fails to parse is fatal — silently falling back to defaults would hide
/// a typo'd wordlist or a misspelled provider until the user noticed their
/// dictation behaving oddly.
struct Config: Decodable {
    var model: String?
    /// Languages you actually speak, as ISO codes. Empty means no constraint.
    /// See `LanguageSelection` for what this does and does not do.
    var languages: [String]
    var hotkey: String
    var latch: LatchConfig
    var cleanup: CleanupConfig
    var wordlist: WordlistConfig
    var history: HistoryConfig
    var stats: StatsConfig
    var overlay: OverlayConfig

    static let `default` = Config()

    private init() {
        model = nil
        languages = []
        hotkey = "fn"
        latch = .default
        cleanup = .default
        wordlist = .default
        history = .default
        stats = .default
        overlay = .default
    }

    private enum CodingKeys: String, CodingKey {
        case model, languages, hotkey
        case latch = "hotkey_latch"
        case cleanup, wordlist, history, stats, overlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        model = try c.decodeIfPresent(String.self, forKey: .model)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? d.languages
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        latch = try c.decodeIfPresent(LatchConfig.self, forKey: .latch) ?? d.latch
        cleanup = try c.decodeIfPresent(CleanupConfig.self, forKey: .cleanup) ?? d.cleanup
        wordlist = try c.decodeIfPresent(WordlistConfig.self, forKey: .wordlist) ?? d.wordlist
        history = try c.decodeIfPresent(HistoryConfig.self, forKey: .history) ?? d.history
        stats = try c.decodeIfPresent(StatsConfig.self, forKey: .stats) ?? d.stats
        overlay = try c.decodeIfPresent(OverlayConfig.self, forKey: .overlay) ?? d.overlay
    }

    // MARK: - Loading

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL, Error)
        case malformed(URL, Error)

        var description: String {
            switch self {
            case .unreadable(let url, let e):
                return "could not read \(url.path): \(e.localizedDescription)"
            case .malformed(let url, let e):
                return "invalid TOML in \(url.path): \(e)"
            }
        }
    }

    /// Load from `path`, or return defaults if the file doesn't exist.
    static func load(from url: URL = ParrotPaths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        do {
            return try TOMLDecoder().decode(Config.self, from: data)
        } catch {
            throw LoadError.malformed(url, error)
        }
    }
}

// MARK: - Sections

struct LatchConfig: Decodable {
    /// Double-tapping the hotkey keeps recording without holding it.
    var enabled: Bool
    /// A hold shorter than this counts as a tap rather than push-to-talk.
    var tapMs: Int
    /// The second tap must land within this window of the first release.
    var windowMs: Int
    /// Hands-free recordings stop and transcribe after this long.
    var maxSeconds: Int

    static let `default` = LatchConfig(enabled: true, tapMs: 300, windowMs: 300, maxSeconds: 300)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case tapMs = "tap_ms"
        case windowMs = "window_ms"
        case maxSeconds = "max_seconds"
    }

    private init(enabled: Bool, tapMs: Int, windowMs: Int, maxSeconds: Int) {
        self.enabled = enabled
        self.tapMs = tapMs
        self.windowMs = windowMs
        self.maxSeconds = maxSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LatchConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        tapMs = try c.decodeIfPresent(Int.self, forKey: .tapMs) ?? d.tapMs
        windowMs = try c.decodeIfPresent(Int.self, forKey: .windowMs) ?? d.windowMs
        maxSeconds = try c.decodeIfPresent(Int.self, forKey: .maxSeconds) ?? d.maxSeconds
    }
}

enum CleanupProvider: String, Decodable {
    case apple
    case anthropic
}

struct CleanupConfig: Decodable {
    var enabled: Bool
    var provider: CleanupProvider
    /// Anthropic only; ignored by the on-device provider.
    var model: String
    /// Below this word count, skip cleanup — the latency isn't worth it.
    var minWords: Int
    var timeoutS: Double
    /// Empty means the built-in prompt.
    var prompt: String

    static let `default` = CleanupConfig(
        enabled: false,
        provider: .apple,
        model: "claude-haiku-4-5",
        minWords: 4,
        timeoutS: 3.0,
        prompt: ""
    )

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, model, prompt
        case minWords = "min_words"
        case timeoutS = "timeout_s"
    }

    private init(
        enabled: Bool,
        provider: CleanupProvider,
        model: String,
        minWords: Int,
        timeoutS: Double,
        prompt: String
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.minWords = minWords
        self.timeoutS = timeoutS
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanupConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(CleanupProvider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        minWords = try c.decodeIfPresent(Int.self, forKey: .minWords) ?? d.minWords
        timeoutS = try c.decodeIfPresent(Double.self, forKey: .timeoutS) ?? d.timeoutS
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
    }
}

struct WordlistConfig: Decodable {
    /// Terms the cleanup model is told to preserve verbatim.
    var vocabulary: [String]
    /// Literal find → replace pairs applied to every transcript.
    var replacements: [String: String]

    static let `default` = WordlistConfig(vocabulary: [], replacements: [:])

    private init(vocabulary: [String], replacements: [String: String]) {
        self.vocabulary = vocabulary
        self.replacements = replacements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WordlistConfig.default
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements)
            ?? d.replacements
    }

    private enum CodingKeys: String, CodingKey {
        case vocabulary, replacements
    }
}

/// How the recording pill visualises your voice.
enum OverlayStyle: String, Decodable {
    /// Scrolling bar meter — newest sample enters right and travels left.
    case bars
    /// Siri-style stroked wave that lies flat when silent.
    case line
}

struct OverlayConfig: Decodable {
    var style: OverlayStyle
    /// Meter sensitivity. 1.0 is the default; higher lowers the noise floor so
    /// quieter mics and softer voices still fill the bars.
    var sensitivity: Double

    static let `default` = OverlayConfig(style: .bars, sensitivity: 1)

    private init(style: OverlayStyle, sensitivity: Double) {
        self.style = style
        self.sensitivity = sensitivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlayConfig.default
        style = try c.decodeIfPresent(OverlayStyle.self, forKey: .style) ?? d.style
        let raw = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        sensitivity = min(3, max(0.25, raw))
    }

    private enum CodingKeys: String, CodingKey {
        case style, sensitivity
    }
}

struct HistoryConfig: Decodable {
    var enabled: Bool
    var maxEntries: Int

    static let `default` = HistoryConfig(enabled: true, maxEntries: 5000)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxEntries = "max_entries"
    }

    private init(enabled: Bool, maxEntries: Int) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HistoryConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? d.maxEntries
    }
}

struct StatsConfig: Decodable {
    var enabled: Bool
    /// The typing speed "time saved" is measured against. An assumption, not a
    /// measurement — surfaced next to the number rather than hidden behind it.
    var typingWpm: Double

    static let `default` = StatsConfig(enabled: true, typingWpm: 40)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case typingWpm = "typing_wpm"
    }

    private init(enabled: Bool, typingWpm: Double) {
        self.enabled = enabled
        self.typingWpm = typingWpm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StatsConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        let raw = try c.decodeIfPresent(Double.self, forKey: .typingWpm) ?? d.typingWpm
        // Clamped so a typo can't divide by zero or claim a decade saved.
        typingWpm = min(200, max(10, raw))
    }
}
