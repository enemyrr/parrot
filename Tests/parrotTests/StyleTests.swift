import XCTest

@testable import parrot

/// Style is one setting read by two features with different contracts. Squawk
/// writes, so it may be told anything; cleanup repairs a transcript, so it may
/// only ever be told about punctuation. These pin that split, and pin the
/// ordering that makes a specific setting beat a general one.
final class StyleToneTests: XCTestCase {
    private func category(
        name: String = "Mail",
        tone: Tone = .formal,
        length: Length = .natural,
        instructions: String = "",
        isFallback: Bool = false
    ) -> StyleCategory {
        StyleCategory(
            name: name,
            symbol: "envelope",
            bundleIDs: ["com.apple.mail"],
            tone: tone,
            length: length,
            instructions: instructions,
            isFallback: isFallback
        )
    }

    // MARK: - Cleanup

    /// The default has to cost nothing. Every dictation pays for this prompt,
    /// and "formal" is what the base prompt already produces.
    func testDefaultToneAddsNothingToCleanup() {
        let plain = CleanupPrompt.instructions(custom: "", context: .empty)
        XCTAssertEqual(plain, CleanupPrompt.base)
    }

    func testToneReachesTheCleanupPrompt() {
        let prompt = CleanupPrompt.instructions(
            custom: "",
            context: CleanupContext(vocabulary: [], languages: [], category: category(tone: .casual))
        )
        XCTAssertTrue(prompt.contains("Punctuate lightly"))
    }

    /// The fence. Cleanup is allowed to repunctuate for a tone and to format for
    /// an app — it is never allowed to rewrite, and a model handed a tone will
    /// happily start "improving" the wording without being told so.
    func testStyledCleanupIsToldNotToRewrite() {
        let prompt = CleanupPrompt.instructions(
            custom: "",
            context: CleanupContext(vocabulary: [], languages: [], category: category(tone: .casual))
        )
        XCTAssertTrue(prompt.contains("keep the speaker's words"))
    }

    /// No tone and no notes means no fence either — there is nothing to fence.
    func testUnstyledCleanupGetsNoExtraRule() {
        XCTAssertFalse(
            CleanupPrompt.instructions(custom: "", context: .empty)
                .contains("keep the speaker's words")
        )
    }

    /// The base prompt is user-editable. Replacing it must not silently drop the
    /// knobs the Style pane says are on — the same reason the language line is
    /// appended rather than embedded.
    func testToneSurvivesACustomCleanupPrompt() {
        let prompt = CleanupPrompt.instructions(
            custom: "FIX COMMAS ONLY",
            context: CleanupContext(vocabulary: [], languages: [], category: category(tone: .excited))
        )
        XCTAssertTrue(prompt.hasPrefix("FIX COMMAS ONLY"))
        XCTAssertTrue(prompt.contains("exclamation mark"))
    }

    func testCategoryNotesFormatTheCleanupPrompt() {
        let prompt = CleanupPrompt.instructions(
            custom: "",
            context: CleanupContext(
                vocabulary: [],
                languages: [],
                category: category(name: "Messages", instructions: "Keep it lowercase.")
            )
        )
        XCTAssertTrue(prompt.contains("This is Messages"))
        XCTAssertTrue(prompt.contains("Keep it lowercase."))
    }

    /// A category with nothing written in it is not a reason to tell the model
    /// anything, including the don't-rewrite fence.
    func testCategoryWithNoNotesChangesNothing() {
        let prompt = CleanupPrompt.instructions(
            custom: "",
            context: CleanupContext(
                vocabulary: [], languages: [], category: category(instructions: "  ")
            )
        )
        XCTAssertEqual(prompt, CleanupPrompt.base)
    }

    /// "Other" is a tab label, not a place you write. Its notes still
    /// apply; its name is the part that would only confuse a model.
    func testTheFallbackIsNotNamedToTheModel() {
        let prompt = CleanupPrompt.instructions(
            custom: "",
            context: CleanupContext(
                vocabulary: [],
                languages: [],
                category: category(
                    name: "Other", instructions: "Keep it lowercase.", isFallback: true
                )
            )
        )
        XCTAssertFalse(prompt.contains("This is Other"))
        XCTAssertTrue(prompt.contains("Keep it lowercase."))
    }

    // MARK: - Squawk

    func testDefaultToneAndLengthAddNothingToSquawk() {
        let system = SquawkPrompt.system(
            settings: .default, style: .default, category: StyleSettings.default.fallback
        )
        XCTAssertFalse(system.contains("Tone:"))
        XCTAssertFalse(system.contains("Length:"))
    }

    func testToneAndLengthReachTheSquawkPrompt() {
        let system = SquawkPrompt.system(
            settings: .default,
            style: .default,
            category: category(tone: .casual, length: .direct)
        )
        XCTAssertTrue(system.contains("Tone: casual"))
        XCTAssertTrue(system.contains("Length: as short as"))
    }

    /// Ordered least specific to most, so recency lets the more specific setting
    /// win: a note that says "lowercase, no punctuation" should beat the
    /// category's own tone, because whoever wrote the note was being more
    /// specific than whoever picked the tone.
    func testTheNotesComeAfterTheTone() {
        let system = SquawkPrompt.system(
            settings: .default,
            style: .default,
            category: category(name: "Slack", tone: .excited, instructions: "Lowercase.")
        )
        XCTAssertLessThan(
            system.range(of: "Tone: warm")!.lowerBound,
            system.range(of: "Lowercase.")!.lowerBound
        )
    }

    /// About you is who is speaking; the tone is how. The first is the more
    /// general claim, so it goes first and the tone can sharpen it.
    func testAboutComesBeforeTheTone() {
        var style = StyleSettings.default
        style.about = "I'm Andreas."
        let system = SquawkPrompt.system(
            settings: .default, style: style, category: category(tone: .casual)
        )
        XCTAssertLessThan(
            system.range(of: "I'm Andreas.")!.lowerBound,
            system.range(of: "Tone: casual")!.lowerBound
        )
    }
}

final class StyleCategoryTests: XCTestCase {
    func testMatchesExactBundleIDCaseInsensitively() {
        let category = StyleCategory(name: "Mail", symbol: "envelope", bundleIDs: ["com.apple.mail"])
        XCTAssertTrue(category.matches("com.apple.Mail"))
        XCTAssertFalse(category.matches("com.apple.mailbox"))
    }

    /// Chromium ships helper processes under suffixed ids, and a category for
    /// the browser should cover them.
    func testWildcardMatchesASuffix() {
        let category = StyleCategory(
            name: "Chrome", symbol: "globe", bundleIDs: ["com.google.Chrome*"]
        )
        XCTAssertTrue(category.matches("com.google.Chrome"))
        XCTAssertTrue(category.matches("com.google.Chrome.helper"))
        XCTAssertFalse(category.matches("com.brave.Browser"))
    }

    /// Order is the tab order, and the pane says so — an app claimed twice
    /// belongs to the leftmost tab that claims it.
    func testFirstMatchingCategoryWins() {
        var style = StyleSettings.default
        style.categories = StyleSettings.normalized([
            StyleCategory(name: "First", symbol: "envelope", bundleIDs: ["com.apple.mail"]),
            StyleCategory(name: "Second", symbol: "envelope", bundleIDs: ["com.apple.mail"]),
            .fallbackStarter,
        ])
        XCTAssertEqual(style.category(for: "com.apple.mail").name, "First")
    }

    /// The point of the catch-all: every call site gets a tone and a length,
    /// including for an app nothing claims and for no app at all.
    func testUnclaimedAppsFallBack() {
        let style = StyleSettings.default
        XCTAssertTrue(style.category(for: "com.unknown.app").isFallback)
        XCTAssertTrue(style.category(for: nil).isFallback)
    }

    func testShippedCategoriesCoverTheObviousApps() {
        let style = StyleSettings.default
        XCTAssertEqual(style.category(for: "com.apple.mail").name, "Email")
        XCTAssertEqual(style.category(for: "com.tinyspeck.slackmacgap").name, "Work messages")
        XCTAssertEqual(style.category(for: "com.apple.MobileSMS").name, "Casual messages")
    }

    /// There used to be a `matchApp` switch that sent dictation to the catch-all
    /// regardless of which app was in front. It's gone — anyone who wants a
    /// category not to claim an app takes the app out of it — and a settings
    /// file still carrying the key must not resurrect that behaviour.
    func testARetiredMatchAppSwitchIsIgnored() throws {
        let json = """
            {"categories":[{"name":"Email","symbol":"envelope","bundleIDs":["com.apple.mail"],
             "tone":"casual","length":"natural","instructions":""},
             {"name":"Other","symbol":"square.grid.2x2","bundleIDs":[],"tone":"formal",
             "length":"natural","instructions":"","isFallback":true}],
             "about":"","matchApp":false}
            """
        let style = try JSONDecoder().decode(StyleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(style.category(for: "com.apple.mail").name, "Email")
    }

    // MARK: - Invariants

    /// The last tab is the one that can't be deleted, and the pane relies on
    /// that. A hand-edited file that put the catch-all first must not make the
    /// Mail tab undeletable.
    func testNormalizingPutsTheFallbackLast() {
        let normalized = StyleSettings.normalized([
            .fallbackStarter,
            StyleCategory(name: "Mail", symbol: "envelope", bundleIDs: ["com.apple.mail"]),
        ])
        XCTAssertEqual(normalized.map(\.name), ["Mail", "Other"])
        XCTAssertTrue(normalized.last!.isFallback)
    }

    /// Two catch-alls is a file someone edited. Demoting the extra keeps what
    /// they wrote, which beats dropping it.
    func testNormalizingKeepsExactlyOneFallback() {
        var second = StyleCategory.fallbackStarter
        second.name = "Also everything"
        let normalized = StyleSettings.normalized([.fallbackStarter, second])
        XCTAssertEqual(normalized.filter(\.isFallback).count, 1)
        XCTAssertEqual(normalized.count, 2)
    }

    func testNormalizingSynthesizesAMissingFallback() {
        let normalized = StyleSettings.normalized([
            StyleCategory(name: "Mail", symbol: "envelope", bundleIDs: ["com.apple.mail"])
        ])
        XCTAssertTrue(normalized.last!.isFallback)
    }

    // MARK: - Migration

    /// The upgrade has to change nothing about how anything is written: every
    /// migrated category carries the tone and length that used to be global.
    func testMigrationCarriesTheOldGlobalToneToEveryCategory() {
        let categories = StyleSettings.migrating(
            tone: .casual,
            length: .thorough,
            profiles: [
                LegacyProfile(
                    name: "Mail", bundleIDs: ["com.apple.mail"], instructions: "Sign off.",
                    enabled: true
                )
            ]
        )
        XCTAssertEqual(categories.map(\.name), ["Mail", "Other"])
        XCTAssertTrue(categories.allSatisfy { $0.tone == .casual && $0.length == .thorough })
        XCTAssertEqual(categories[0].trimmedInstructions, "Sign off.")
    }

    /// A profile switched off used to match nothing. There is no off switch any
    /// more, so an empty note is how it keeps saying nothing — and the apps
    /// stay, which is the part that was laborious to enter.
    func testMigrationEmptiesADisabledProfileWithoutLosingItsApps() {
        let categories = StyleSettings.migrating(
            tone: .formal,
            length: .natural,
            profiles: [
                LegacyProfile(
                    name: "Mail", bundleIDs: ["com.apple.mail"], instructions: "Sign off.",
                    enabled: false
                )
            ]
        )
        XCTAssertEqual(categories[0].bundleIDs, ["com.apple.mail"])
        XCTAssertTrue(categories[0].trimmedInstructions.isEmpty)
    }

    /// Someone who never opened the old pane has the shipped set stored
    /// verbatim. Carrying it across one-for-one would ship the previous
    /// design's tab bar into the new one — so an untouched set becomes the new
    /// starters, still wearing whatever tone they had picked globally.
    func testUntouchedShippedProfilesBecomeTheNewStarters() {
        let shipped = [
            LegacyProfile(
                name: "Mail",
                bundleIDs: ["com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook"],
                instructions: "Full sentences. Keep the greeting and sign off the way the thread "
                    + "does. Don't restate the question you're answering.",
                enabled: true
            ),
            LegacyProfile(
                name: "Messages & chat",
                bundleIDs: ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"],
                instructions: "One short message. No greeting, no sign-off, no subject line. "
                    + "Match the casing and punctuation of the conversation, including lowercase.",
                enabled: true
            ),
            LegacyProfile(
                name: "Slack & Discord",
                bundleIDs: ["com.tinyspeck.slackmacgap", "com.hnc.Discord"],
                instructions: "Short and direct, one paragraph. No greeting. Threads are "
                    + "informal — write the way the channel does.",
                enabled: true
            ),
            LegacyProfile(
                name: "Notes & documents",
                bundleIDs: ["com.apple.Notes", "md.obsidian", "com.apple.TextEdit"],
                instructions: "Prose or bullets, whichever the document already uses. No greeting "
                    + "and no sign-off — this is a document, not a message.",
                enabled: true
            ),
        ]
        let categories = StyleSettings.migrating(tone: .formal, length: .natural, profiles: shipped)
        XCTAssertEqual(categories.map(\.name), StyleCategory.starters.map(\.name))
        XCTAssertTrue(categories.allSatisfy { $0.tone == .formal })
    }

    /// One edited profile makes the whole set theirs, and every one of them
    /// migrates across as its own category. Losing an edit is the failure this
    /// guards.
    func testAnEditedProfileIsNotMistakenForTheShippedSet() {
        let edited = [
            LegacyProfile(
                name: "Mail", bundleIDs: ["com.apple.mail"], instructions: "My own words.",
                enabled: true
            )
        ]
        let categories = StyleSettings.migrating(tone: .casual, length: .natural, profiles: edited)
        XCTAssertEqual(categories.map(\.name), ["Mail", "Other"])
        XCTAssertEqual(categories[0].trimmedInstructions, "My own words.")
    }

    /// A stored blob from before categories existed decodes through the same
    /// path, so the tone someone picked survives the upgrade.
    func testDecodingTheOldStyleShape() throws {
        let json = """
            {"tone":"casual","length":"direct","about":"I'm Andreas.","matchApp":false,
             "profiles":[{"name":"Slack","bundleIDs":["com.tinyspeck.slackmacgap"],
             "instructions":"Lowercase.","enabled":true}]}
            """
        let style = try JSONDecoder().decode(StyleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(style.about, "I'm Andreas.")
        XCTAssertEqual(style.categories.map(\.name), ["Slack", "Other"])
        XCTAssertEqual(style.category(for: "com.tinyspeck.slackmacgap").tone, .casual)
        XCTAssertEqual(style.fallback.length, .direct)
    }

    /// The default tone used to be stored as "professional", beside a separate
    /// "formal". They are one tone now, and a stored value this doesn't know
    /// has to land on the default rather than fail the whole settings file.
    func testARetiredToneDecodesAsTheDefault() throws {
        let json = """
            {"categories":[{"name":"Mail","symbol":"envelope","bundleIDs":["com.apple.mail"],
             "tone":"professional","length":"natural","instructions":"","isFallback":true}],
             "about":"","matchApp":true}
            """
        let style = try JSONDecoder().decode(StyleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(style.fallback.tone, .formal)
    }
}
