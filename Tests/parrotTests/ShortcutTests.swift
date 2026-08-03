import XCTest

@testable import parrot

/// Shortcuts type arbitrary text into the user's window off the back of a
/// phrase they said. Two things have to hold: a trigger fires when it was
/// meant to, and never when it wasn't.
final class ShortcutExpanderTests: XCTestCase {
    private func expander(_ pairs: [(String, String)]) -> ShortcutExpander {
        ShortcutExpander(shortcuts: pairs.map { TextShortcut(trigger: $0.0, expansion: $0.1) })
    }

    func testExpandsATriggerMidSentence() {
        let x = expander([("my email shortcut", "andreas@ribban.co")])
        XCTAssertEqual(
            x.apply(to: "Send it to my email shortcut when you can"),
            "Send it to andreas@ribban.co when you can"
        )
    }

    /// The transcriber capitalises the first word of a sentence, so a trigger
    /// that only matched lowercase would fail exactly when it is said alone.
    func testMatchingIsCaseInsensitive() {
        let x = expander([("my email shortcut", "andreas@ribban.co")])
        XCTAssertEqual(x.apply(to: "My email shortcut."), "andreas@ribban.co.")
    }

    /// Where the commas land is the transcriber's decision, not the speaker's.
    func testPunctuationBetweenTheWordsStillMatches() {
        let x = expander([("my email shortcut", "andreas@ribban.co")])
        XCTAssertEqual(x.apply(to: "Okay, my email, shortcut"), "Okay, andreas@ribban.co")
    }

    func testDoesNotFireInsideALongerWord() {
        let x = expander([("sig", "Andreas Enemyr")])
        XCTAssertEqual(x.apply(to: "the design signal"), "the design signal")
        XCTAssertEqual(x.apply(to: "add sig here"), "add Andreas Enemyr here")
    }

    /// A multi-line expansion is the whole reason this isn't a wordlist rule.
    func testExpansionCanBeSeveralLines() {
        let signature = "Andreas Enemyr\nRibban\nandreas@ribban.co"
        let x = expander([("sign off shortcut", signature)])
        XCTAssertEqual(x.apply(to: "Thanks. sign off shortcut"), "Thanks. \(signature)")
    }

    /// One pass, so an expansion containing another trigger is left alone.
    /// Without it a shortcut whose text mentions a phrase you also made a
    /// shortcut of would rewrite itself.
    func testAnExpansionIsNotRescanned() {
        let x = expander([
            ("greeting shortcut", "hey there, sign off shortcut"),
            ("sign off shortcut", "Andreas"),
        ])
        XCTAssertEqual(x.apply(to: "greeting shortcut"), "hey there, sign off shortcut")
    }

    /// Longest trigger wins where two overlap, so the more specific phrase is
    /// reachable at all.
    func testLongerTriggerWins() {
        let x = expander([("email", "andreas@ribban.co"), ("work email", "andreas@work.example")])
        XCTAssertEqual(x.apply(to: "my work email"), "my andreas@work.example")
    }

    /// A row still being filled in sits in settings without firing — otherwise
    /// typing a trigger would blank out that phrase in the next dictation.
    func testHalfTypedRowsAreInert() {
        let x = expander([("my email shortcut", "")])
        XCTAssertTrue(x.isEmpty)
        XCTAssertEqual(x.apply(to: "my email shortcut"), "my email shortcut")
    }

    func testTriggersAreExposedForVocabularyHints() {
        let x = expander([("my email shortcut", "andreas@ribban.co"), ("", "orphan")])
        XCTAssertEqual(x.triggers, ["my email shortcut"])
    }

    /// Two rows with the same trigger can't both win; the first one shown in
    /// settings is the one that fires.
    func testDuplicateTriggersKeepTheFirst() {
        let x = expander([("mine", "first"), ("Mine", "second")])
        XCTAssertEqual(x.triggers, ["mine"])
        XCTAssertEqual(x.apply(to: "mine"), "first")
    }
}

/// The wordlist and shortcuts share `PhraseRules`; these pin the behaviour the
/// wordlist relies on, which the loose-spacing option must not have changed.
final class PhraseRulesTests: XCTestCase {
    func testSingleLeftToRightPass() {
        let rules = PhraseRules([("claude code", "Claude Code"), ("claude", "Claude")])
        XCTAssertEqual(rules.apply(to: "claude code and claude"), "Claude Code and Claude")
    }

    /// Word boundaries are only applied where they can fire — a key ending in
    /// punctuation would otherwise never match.
    func testKeysEndingInPunctuationStillMatch() {
        let rules = PhraseRules([("c++", "C++")])
        XCTAssertEqual(rules.apply(to: "writing c++ today"), "writing C++ today")
    }

    /// Strict spacing is the wordlist's contract: it repairs text the
    /// transcriber already committed to, so it must not reach across a comma
    /// the speaker meant to be there.
    func testStrictSpacingDoesNotSpanPunctuation() {
        let rules = PhraseRules([("claude code", "Claude Code")])
        XCTAssertEqual(rules.apply(to: "claude, code"), "claude, code")
    }

    func testEmptyRulesLeaveTextAlone() {
        let rules = PhraseRules([])
        XCTAssertTrue(rules.isEmpty)
        XCTAssertEqual(rules.apply(to: "untouched"), "untouched")
    }
}

/// The wordlist runs before shortcuts do, so it gets first refusal on the words
/// a trigger is made of. Rewriting one leaves a phrase the expander no longer
/// recognises and a shortcut that silently stops working — the failure the
/// pipeline fences against by handing the wordlist the trigger spans.
final class TriggerFencingTests: XCTestCase {
    private let shortcuts = ShortcutExpander(shortcuts: [
        TextShortcut(trigger: "java script shortcut", expansion: "console.log()")
    ])
    private let wordlist = Wordlist(
        settings: WordlistSettings(
            vocabulary: [],
            replacements: [Replacement(from: "java script", to: "JavaScript")]
        )
    )

    func testTheWordlistLeavesATriggerAlone() {
        let said = "run java script shortcut now"
        let corrected = wordlist.apply(to: said, excluding: shortcuts.triggerRanges(in: said))
        XCTAssertEqual(corrected, said)
        XCTAssertEqual(shortcuts.apply(to: corrected), "run console.log() now")
    }

    /// Only the trigger is fenced. The same words said outside one are still an
    /// ordinary misspelling for the wordlist to fix.
    func testTheSameWordsOutsideATriggerAreStillCorrected() {
        let said = "java script is fine, and java script shortcut"
        let corrected = wordlist.apply(to: said, excluding: shortcuts.triggerRanges(in: said))
        XCTAssertEqual(corrected, "JavaScript is fine, and java script shortcut")
        XCTAssertEqual(shortcuts.apply(to: corrected), "JavaScript is fine, and console.log()")
    }

    /// Without the fence the trigger's words get fused and the expansion never
    /// happens — pinned so the ordering can't quietly regress.
    func testWithoutTheFenceTheShortcutStopsFiring() {
        let said = "run java script shortcut now"
        let corrected = wordlist.apply(to: said)
        XCTAssertEqual(corrected, "run JavaScript shortcut now")
        XCTAssertEqual(shortcuts.apply(to: corrected), corrected)
    }
}
