import Foundation
import TOMLDecoder

/// One-time import of the `config.toml` that settings used to live in.
///
/// The file is gone from the product, but people have wordlists and API-model
/// choices in theirs, and dropping those on upgrade would be the kind of silent
/// data loss that is never worth the tidiness. So the first launch after the
/// change reads the old file, folds it into `Settings`, and renames it — the
/// rename is what makes this run exactly once, and it leaves the original on
/// disk in case the import got something wrong.
///
/// Every section decodes independently. The old loader treated a malformed file
/// as fatal, which was right when it was the live configuration; here it is not
/// — a single bad line shouldn't cost the user the other nine sections.
enum LegacyConfigMigration {
    static var legacyFile: URL {
        ParrotPaths.configDirectory.appendingPathComponent("config.toml")
    }

    static var retiredFile: URL {
        ParrotPaths.configDirectory.appendingPathComponent("config.toml.migrated")
    }

    /// Import if there is anything to import. Returns the imported settings, or
    /// nil when there was no legacy file (the overwhelmingly common case).
    @discardableResult
    static func runIfNeeded() -> Settings? {
        let url = legacyFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Stored settings win, always. The rename below is best-effort — an
        // unwritable config directory, or a dotfile manager putting the file
        // back — and without this guard every one of those cases re-imports the
        // old TOML on each launch, silently reverting everything the user has
        // changed in the settings window since.
        guard !SettingsStore.hasStoredSettings else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        // A file that doesn't parse at all has nothing to import. Retiring it
        // and announcing success would tell the user their settings came across
        // while quietly replacing them with defaults.
        guard let imported = settings(fromTOML: data) else {
            FileHandle.standardError.write(Data("""
                \(url.path) could not be parsed, so nothing was imported
                  fix the file and restart, or set things up in the Settings window

                """.utf8))
            return nil
        }
        SettingsStore.persist(imported)

        // Rename last: if anything above threw, the next launch gets to retry
        // rather than losing the file with nothing to show for it.
        try? FileManager.default.removeItem(at: retiredFile)
        try? FileManager.default.moveItem(at: url, to: retiredFile)

        FileHandle.standardError.write(Data("""
            imported settings from \(url.path)
              settings now live in the Settings window (parrot settings)
              the old file has been kept as \(retiredFile.lastPathComponent)

            """.utf8))
        return imported
    }

    /// Exposed separately from the file handling so the mapping can be tested
    /// against a TOML string without touching the user's home directory.
    ///
    /// Nil means the file isn't TOML at all — distinct from a file whose
    /// individual sections don't decode, which yields defaults for those
    /// sections and keeps the rest.
    static func settings(fromTOML data: Data) -> Settings? {
        guard let legacy = try? TOMLDecoder().decode(LegacyConfig.self, from: data) else {
            return nil
        }
        return legacy.asSettings()
    }
}

/// The shape of the retired `config.toml`. Frozen — nothing new goes in here.
private struct LegacyConfig: Decodable {
    var model: String?
    var languages: [String]?
    var hotkey: String?
    var latch: Latch?
    var cleanup: Cleanup?
    var wordlist: Wordlist?
    var history: History?
    var stats: Stats?
    var overlay: Overlay?

    private enum CodingKeys: String, CodingKey {
        case model, languages, hotkey
        case latch = "hotkey_latch"
        case cleanup, wordlist, history, stats, overlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` per key, not per file: one unparseable section shouldn't take
        // the rest of a working config down with it.
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        languages = try? c.decodeIfPresent([String].self, forKey: .languages)
        hotkey = try? c.decodeIfPresent(String.self, forKey: .hotkey)
        latch = try? c.decodeIfPresent(Latch.self, forKey: .latch)
        cleanup = try? c.decodeIfPresent(Cleanup.self, forKey: .cleanup)
        wordlist = try? c.decodeIfPresent(Wordlist.self, forKey: .wordlist)
        history = try? c.decodeIfPresent(History.self, forKey: .history)
        stats = try? c.decodeIfPresent(Stats.self, forKey: .stats)
        overlay = try? c.decodeIfPresent(Overlay.self, forKey: .overlay)
    }

    struct Latch: Decodable {
        var enabled: Bool?
        var tapMs: Int?
        var windowMs: Int?
        var maxSeconds: Int?

        private enum CodingKeys: String, CodingKey {
            case enabled
            case tapMs = "tap_ms"
            case windowMs = "window_ms"
            case maxSeconds = "max_seconds"
        }
    }

    struct Cleanup: Decodable {
        var enabled: Bool?
        var provider: String?
        var model: String?
        var reasoningEffort: String?
        var minWords: Int?
        var timeoutS: Double?
        var prompt: String?

        private enum CodingKeys: String, CodingKey {
            case enabled, provider, model, prompt
            case reasoningEffort = "reasoning_effort"
            case minWords = "min_words"
            case timeoutS = "timeout_s"
        }
    }

    struct Wordlist: Decodable {
        var vocabulary: [String]?
        var replacements: [String: String]?
    }

    struct History: Decodable {
        var enabled: Bool?
        var maxEntries: Int?

        private enum CodingKeys: String, CodingKey {
            case enabled
            case maxEntries = "max_entries"
        }
    }

    struct Stats: Decodable {
        var enabled: Bool?
        var typingWpm: Double?

        private enum CodingKeys: String, CodingKey {
            case enabled
            case typingWpm = "typing_wpm"
        }
    }

    struct Overlay: Decodable {
        var style: String?
        var sensitivity: Double?
    }

    func asSettings() -> Settings {
        let d = Settings.default

        // An id that no longer exists resolves through the retirement table, so
        // a config naming a Whisper model still lands somewhere usable.
        let resolvedModel = model.flatMap { ModelRegistry.find($0)?.id } ?? d.model

        return Settings(
            model: resolvedModel,
            languages: languages ?? d.languages,
            // The TOML config never had a device picker — it recorded from
            // whatever macOS was using, which is what the default still means.
            audio: d.audio,
            hotkey: hotkey.flatMap(Hotkey.preset(named:)) ?? d.hotkey,
            latch: LatchSettings(
                enabled: latch?.enabled ?? d.latch.enabled,
                tapMs: latch?.tapMs ?? d.latch.tapMs,
                windowMs: latch?.windowMs ?? d.latch.windowMs,
                maxSeconds: latch?.maxSeconds ?? d.latch.maxSeconds
            ),
            // Squawk postdates the TOML config entirely — there is nothing to
            // import, and it stays off until someone turns it on. Style came
            // with it, so it starts at its defaults too.
            squawk: d.squawk,
            style: d.style,
            cleanup: CleanupSettings(
                enabled: cleanup?.enabled ?? d.cleanup.enabled,
                provider: cleanup?.provider.flatMap(LLMProvider.init(rawValue:))
                    ?? d.cleanup.provider,
                model: cleanup?.model ?? d.cleanup.model,
                reasoningEffort: cleanup?.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
                    ?? d.cleanup.reasoningEffort,
                minWords: cleanup?.minWords ?? d.cleanup.minWords,
                timeoutS: cleanup?.timeoutS ?? d.cleanup.timeoutS,
                prompt: cleanup?.prompt ?? d.cleanup.prompt
            ),
            wordlist: WordlistSettings(
                vocabulary: wordlist?.vocabulary ?? d.wordlist.vocabulary,
                // Sorted so the imported table has a stable order rather than
                // whatever the dictionary happened to hash to.
                replacements: (wordlist?.replacements ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { Replacement(from: $0.key, to: $0.value) }
            ),
            // Shortcuts and integrations both postdate the TOML config, same as
            // squawk — nothing to import.
            shortcuts: d.shortcuts,
            integrations: d.integrations,
            history: HistorySettings(
                enabled: history?.enabled ?? d.history.enabled,
                maxEntries: history?.maxEntries ?? d.history.maxEntries
            ),
            stats: StatsSettings(
                enabled: stats?.enabled ?? d.stats.enabled,
                typingWpm: stats?.typingWpm ?? d.stats.typingWpm
            ),
            // `overlay.style` and `overlay.enabled` were config keys once. The
            // pill's look now follows the mode rather than a preference, and it
            // no longer switches off, so an imported one is read and dropped.
            overlay: OverlaySettings(
                sensitivity: overlay?.sensitivity ?? d.overlay.sensitivity
            )
        )
    }
}
