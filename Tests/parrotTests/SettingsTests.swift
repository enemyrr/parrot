import XCTest

@testable import parrot

/// Settings are one JSON blob in preferences now. Two things have to hold for
/// that to be safe: a blob written by an older build must still load, and the
/// values that feed arithmetic must stay inside their ranges however they were
/// set.
final class SettingsCodingTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testRoundTrips() throws {
        var original = Settings.default
        original.hotkey = .option
        original.languages = ["en", "sv"]
        original.cleanup.enabled = true
        original.cleanup.provider = .openai
        original.cleanup.reasoningEffort = .low
        original.wordlist.vocabulary = ["Vercel"]
        original.wordlist.replacements = [Replacement(from: "vercell", to: "Vercel")]
        original.overlay.style = .line

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A preset hotkey encodes as a bare string; a recorded one takes the keyed
    /// shape, and that path had no coverage. A regression in it would reset
    /// every custom shortcut to the default on the next launch.
    func testRecordedShortcutRoundTrips() throws {
        var original = Settings.default
        original.hotkey = Hotkey(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.hotkey, original.hotkey)
        XCTAssertEqual(decoded.hotkey.keyLabel, "Space")
        XCTAssertEqual(decoded, original)
    }

    /// The forward-compatibility guarantee: an empty object is every default,
    /// not a decode failure that would silently reset someone's setup.
    func testMissingKeysTakeDefaults() throws {
        XCTAssertEqual(try decode("{}"), Settings.default)
    }

    func testPartialBlobKeepsItsValuesAndDefaultsTheRest() throws {
        let settings = try decode(#"{"hotkey":"control","history":{"enabled":false}}"#)
        XCTAssertEqual(settings.hotkey, .control)
        XCTAssertFalse(settings.history.enabled)
        // Untouched sections are untouched, not zeroed.
        XCTAssertEqual(settings.history.maxEntries, HistorySettings.default.maxEntries)
        XCTAssertEqual(settings.latch, LatchSettings.default)
        XCTAssertEqual(settings.model, Settings.default.model)
    }

    func testSensitivityIsClampedWheneverItIsSet() throws {
        XCTAssertEqual(try decode(#"{"overlay":{"sensitivity":99}}"#).overlay.sensitivity, 3)
        XCTAssertEqual(try decode(#"{"overlay":{"sensitivity":0}}"#).overlay.sensitivity, 0.25)

        var settings = Settings.default
        settings.overlay.sensitivity = -5
        XCTAssertEqual(settings.overlay.sensitivity, 0.25)
    }

    func testTypingSpeedIsClampedWheneverItIsSet() throws {
        XCTAssertEqual(try decode(#"{"stats":{"typingWpm":0}}"#).stats.typingWpm, 10)

        var settings = Settings.default
        settings.stats.typingWpm = 9999
        XCTAssertEqual(settings.stats.typingWpm, 200)
    }

    /// A model id that has since been retired still has to resolve to something
    /// loadable — refusing to start over a stale preference would be worse.
    func testResolvedModelFallsBackForAnUnknownID() {
        var settings = Settings.default
        settings.model = "no-such-model"
        XCTAssertEqual(settings.resolvedModel.id, ModelRegistry.recommended()?.id)
    }

    /// Half-typed rules live in the table while the user is still filling them
    /// in; they must not reach the replacer as an empty-key rule.
    func testBlankReplacementRulesAreDroppedFromTheMap() {
        let wordlist = WordlistSettings(
            vocabulary: [],
            replacements: [
                Replacement(from: "vercell", to: "Vercel"),
                Replacement(from: "   ", to: "nope"),
                Replacement(from: "", to: "nope"),
            ]
        )
        XCTAssertEqual(wordlist.replacementMap, ["vercell": "Vercel"])
    }
}

/// The old `config.toml` is gone from the product, but people have wordlists in
/// theirs. The import runs exactly once and must not lose anything.
final class LegacyConfigMigrationTests: XCTestCase {
    private func migrate(_ toml: String) -> Settings {
        guard let settings = LegacyConfigMigration.settings(fromTOML: Data(toml.utf8)) else {
            XCTFail("expected \(toml) to parse")
            return .default
        }
        return settings
    }

    /// A file that isn't TOML at all has nothing to import, and saying so is the
    /// difference between the user fixing it and the user quietly getting
    /// defaults while being told their settings came across.
    func testUnparseableFileImportsNothing() {
        XCTAssertNil(LegacyConfigMigration.settings(fromTOML: Data("[[[ not toml".utf8)))
    }

    func testImportsEverySection() {
        let settings = migrate("""
            model  = "parakeet-v2"
            hotkey = "option"
            languages = ["en", "sv"]

            [hotkey_latch]
            enabled     = false
            tap_ms      = 250
            window_ms   = 400
            max_seconds = 120

            [cleanup]
            enabled   = true
            provider  = "openai"
            model     = "gpt-5-mini"
            reasoning_effort = "low"
            min_words = 7
            timeout_s = 6.5
            prompt    = "be terse"

            [wordlist]
            vocabulary = ["Vercel", "FluidAudio"]

            [wordlist.replacements]
            "claude code" = "Claude Code"
            "vercell"     = "Vercel"

            [history]
            enabled     = false
            max_entries = 99

            [stats]
            enabled = false
            typing_wpm = 65

            [overlay]
            style = "line"
            sensitivity = 1.8
            """)

        XCTAssertEqual(settings.model, "parakeet-v2")
        XCTAssertEqual(settings.hotkey, .option)
        XCTAssertEqual(settings.languages, ["en", "sv"])

        XCTAssertFalse(settings.latch.enabled)
        XCTAssertEqual(settings.latch.tapMs, 250)
        XCTAssertEqual(settings.latch.windowMs, 400)
        XCTAssertEqual(settings.latch.maxSeconds, 120)

        XCTAssertTrue(settings.cleanup.enabled)
        XCTAssertEqual(settings.cleanup.provider, .openai)
        XCTAssertEqual(settings.cleanup.model, "gpt-5-mini")
        XCTAssertEqual(settings.cleanup.reasoningEffort, .low)
        XCTAssertEqual(settings.cleanup.minWords, 7)
        XCTAssertEqual(settings.cleanup.timeoutS, 6.5)
        XCTAssertEqual(settings.cleanup.prompt, "be terse")

        XCTAssertEqual(settings.wordlist.vocabulary, ["Vercel", "FluidAudio"])
        XCTAssertEqual(
            settings.wordlist.replacementMap,
            ["claude code": "Claude Code", "vercell": "Vercel"]
        )

        XCTAssertFalse(settings.history.enabled)
        XCTAssertEqual(settings.history.maxEntries, 99)
        XCTAssertFalse(settings.stats.enabled)
        XCTAssertEqual(settings.stats.typingWpm, 65)
        XCTAssertEqual(settings.overlay.style, .line)
        XCTAssertEqual(settings.overlay.sensitivity, 1.8, accuracy: 1e-9)
    }

    func testEmptyFileIsEveryDefault() {
        XCTAssertEqual(migrate(""), Settings.default)
    }

    /// The old loader treated a malformed file as fatal, which was right when
    /// it was live configuration. During a one-shot import it is not: a single
    /// bad section shouldn't cost the user the other nine.
    func testOneBadSectionDoesNotTakeTheRestWithIt() {
        let settings = migrate("""
            hotkey = "control"

            [hotkey_latch]
            tap_ms = "not a number"

            [wordlist]
            vocabulary = ["Vercel"]
            """)

        XCTAssertEqual(settings.hotkey, .control)
        XCTAssertEqual(settings.wordlist.vocabulary, ["Vercel"])
        XCTAssertEqual(settings.latch, LatchSettings.default)
    }

    func testRetiredModelIDsResolveToTheirReplacement() {
        XCTAssertEqual(migrate(#"model = "whisper-large-v3-turbo""#).model, "parakeet-v3")
    }

    /// The old file accepted spellings the picker no longer offers.
    func testHotkeyAliases() {
        XCTAssertEqual(migrate(#"hotkey = "globe""#).hotkey, .fn)
        XCTAssertEqual(migrate(#"hotkey = "cmd""#).hotkey, .command)
        XCTAssertEqual(migrate(#"hotkey = "right-option""#).hotkey, .option)
        // Unrecognised falls back rather than failing the whole import.
        XCTAssertEqual(migrate(#"hotkey = "capslock""#).hotkey, Settings.default.hotkey)
    }
}
