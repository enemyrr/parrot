import XCTest

@testable import parrot

/// The parts of squawk that decide what gets typed into someone's window.
/// Everything here is reachable without a model, a microphone or a screen.
final class SquawkResponseTests: XCTestCase {
    func testParsesTheStructuredAnswer() {
        let parsed = SquawkResponse.parse(
            #"{"action":"replace","text":"Hej Sara, det kvarstår."}"#,
            fallback: .insert
        )
        XCTAssertEqual(parsed?.action, .replace)
        XCTAssertEqual(parsed?.text, "Hej Sara, det kvarstår.")
    }

    /// The on-device provider is asked for JSON in the prompt rather than held
    /// to a schema, and wraps it in a fence often enough to matter.
    func testParsesJSONInsideACodeFence() {
        let parsed = SquawkResponse.parse(
            "```json\n{\"action\":\"insert\",\"text\":\"Ten works.\"}\n```",
            fallback: .replace
        )
        XCTAssertEqual(parsed?.action, .insert)
        XCTAssertEqual(parsed?.text, "Ten works.")
    }

    /// Bare prose is the common on-device failure, and it is recoverable: the
    /// text is the answer, and the fallback says where it goes.
    func testBareProseFallsBackToTheCallersAction() {
        let parsed = SquawkResponse.parse("Ten o'clock works for me.", fallback: .replace)
        XCTAssertEqual(parsed?.action, .replace)
        XCTAssertEqual(parsed?.text, "Ten o'clock works for me.")
    }

    /// An answer in the agreed shape that says nothing is an empty answer, not
    /// prose. Falling through to the prose path here would type the JSON itself
    /// into the user's field.
    func testEmptyStructuredAnswerIsNil() {
        XCTAssertNil(SquawkResponse.parse(#"{"action":"replace","text":"   "}"#, fallback: .insert))
        XCTAssertNil(SquawkResponse.parse(#"{"action":"insert","text":""}"#, fallback: .insert))
    }

    func testUnknownActionTakesTheFallback() {
        let parsed = SquawkResponse.parse(
            #"{"action":"rewrite","text":"hi"}"#, fallback: .insert
        )
        XCTAssertEqual(parsed?.action, .insert)
    }

    func testNothingAtAllIsNil() {
        XCTAssertNil(SquawkResponse.parse("   \n  ", fallback: .insert))
    }
}

final class SquawkGuardTests: XCTestCase {
    /// A refusal typed into someone's half-written email is worse than a squawk
    /// that quietly does nothing.
    func testRefusalsAreRejected() {
        XCTAssertFalse(SquawkGuard.accept("I'm sorry, I can't help with that.", maxCharacters: 4000))
        XCTAssertFalse(SquawkGuard.accept("As an AI language model, I…", maxCharacters: 4000))
        // Meta-preambles are the other way a model answers without answering.
        XCTAssertFalse(SquawkGuard.accept("Here's the rewritten email:", maxCharacters: 4000))
    }

    func testOrdinaryTextIsAccepted() {
        XCTAssertTrue(SquawkGuard.accept("Ten o'clock works — see you then.", maxCharacters: 4000))
        // A reply that happens to be an apology is not a refusal.
        XCTAssertTrue(SquawkGuard.accept("Sorry for the slow reply!", maxCharacters: 4000))
    }

    func testRunawayOutputIsRejected() {
        XCTAssertFalse(SquawkGuard.accept(String(repeating: "a", count: 5000), maxCharacters: 4000))
        XCTAssertFalse(SquawkGuard.accept("", maxCharacters: 4000))
    }

    func testFullyQuotedTextIsUnwrapped() {
        XCTAssertEqual(SquawkGuard.unwrap("\"Ten works.\""), "Ten works.")
        // Internal quotes mean the quoting is part of the answer.
        XCTAssertEqual(
            SquawkGuard.unwrap("She said \"no\" twice"),
            "She said \"no\" twice"
        )
    }
}

final class SquawkPromptTests: XCTestCase {
    private func context(
        selection: String? = nil,
        focused: String? = nil,
        window: String? = nil
    ) -> ScreenContext {
        ScreenContext(
            app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: Q3",
            selection: selection, focusedText: focused, windowText: window,
            truncated: false, skipped: nil, elapsed: 0
        )
    }

    /// The instruction goes last and is the only thing tagged as a request.
    func testScreenContentsAreTaggedAsData() {
        let user = SquawkPrompt.user(
            instruction: "answer this friendly",
            context: context(window: "Can you do Tuesday?")
        )
        XCTAssertTrue(user.contains("<visible-text>"))
        XCTAssertTrue(user.contains("<instruction>\nanswer this friendly\n</instruction>"))
        // The instruction is last: it is the only part that is a request.
        XCTAssertTrue(user.hasSuffix("</instruction>"))
    }

    func testEachContextSourceGetsItsOwnTag() {
        let user = SquawkPrompt.user(
            instruction: "rewrite",
            context: context(selection: "S", focused: "F", window: "W")
        )
        XCTAssertTrue(user.contains("<selection>"))
        XCTAssertTrue(user.contains("<field-the-cursor-is-in>"))
        XCTAssertTrue(user.contains("<visible-text>"))
    }

    /// An unreadable app and a blank one are different situations, and a model
    /// handed empty tags treats the second as the first.
    func testUnreadableScreenSaysSoRatherThanSendingEmptyTags() {
        let user = SquawkPrompt.user(
            instruction: "reply",
            context: .skipped(.excludedApp, app: "1Password")
        )
        XCTAssertTrue(user.contains("nothing readable"))
        XCTAssertFalse(user.contains("<visible-text>"))
    }

    /// A window title with a quote in it would otherwise close the attribute
    /// early and hand the model a malformed tag.
    func testWindowTitleQuotesAreEscaped() {
        let context = ScreenContext(
            app: "Mail", bundleID: nil, windowTitle: "Re: \"urgent\"",
            selection: "x", focusedText: nil, windowText: nil,
            truncated: false, skipped: nil, elapsed: 0
        )
        let user = SquawkPrompt.user(instruction: "reply", context: context)
        XCTAssertTrue(user.contains("window=\"Re: 'urgent'\""))
    }

    func testCustomPromptReplacesTheBaseAndKeepsTheLayers() {
        var settings = SquawkSettings.default
        settings.prompt = "BE TERSE"
        var style = StyleSettings.default
        style.about = "I'm Andreas."
        let category = StyleCategory(
            name: "Mail", symbol: "envelope", bundleIDs: ["com.apple.mail"],
            instructions: "Sign off."
        )

        let system = SquawkPrompt.system(settings: settings, style: style, category: category)
        XCTAssertTrue(system.hasPrefix("BE TERSE"))
        XCTAssertFalse(system.contains("You write text that is about to be typed"))
        XCTAssertTrue(system.contains("I'm Andreas."))
        XCTAssertTrue(system.contains("Sign off."))
    }

    func testEmptyPromptFallsBackToTheBuiltIn() {
        let system = SquawkPrompt.system(settings: .default, style: .default, category: StyleSettings.default.fallback)
        XCTAssertTrue(system.contains("You write text that is about to be typed"))
    }

    // MARK: - Language

    /// The base prompt is user-editable, so the language rule is appended
    /// rather than embedded — replacing the base prompt can't silently drop it.
    func testLanguageRuleSurvivesACustomBasePrompt() {
        var settings = SquawkSettings.default
        settings.prompt = "BE TERSE"
        let system = SquawkPrompt.system(settings: settings, style: .default, category: StyleSettings.default.fallback)
        XCTAssertTrue(system.hasPrefix("BE TERSE"))
        XCTAssertTrue(system.contains("Language."))
    }

    /// Configured languages are a tiebreaker for an unreadable screen, not a
    /// constraint — so they only appear when there are some.
    func testConfiguredLanguagesAppearOnlyWhenSet() {
        let with = SquawkPrompt.system(
            settings: .default, style: .default, category: StyleSettings.default.fallback, languages: ["English", "Swedish"]
        )
        XCTAssertTrue(with.contains("English and Swedish"))
        XCTAssertFalse(
            SquawkPrompt.system(settings: .default, style: .default, category: StyleSettings.default.fallback, languages: [])
                .contains("English and Swedish")
        )
    }

    /// Last in the system prompt, where recency helps it stick — and after the
    /// category's notes, which it defers to.
    func testLanguageRuleComesAfterTheCategoryNotes() {
        let category = StyleCategory(
            name: "Mail", symbol: "envelope", bundleIDs: ["com.apple.mail"],
            instructions: "Sign off."
        )
        let system = SquawkPrompt.system(settings: .default, style: .default, category: category)
        XCTAssertLessThan(
            system.range(of: "Sign off.")!.lowerBound,
            system.range(of: "Language.")!.lowerBound
        )
    }
}

/// Reasoning tokens are billed against `max_output_tokens` and spent before the
/// answer, so getting the headroom wrong returns an empty reply rather than a
/// short one.
final class OpenAIBudgetTests: XCTestCase {
    /// The regression. "Not set" omits the `reasoning` parameter, which means
    /// the model's *default* effort — not "off" — so a reasoning model reasons
    /// anyway. Reserving nothing here made every long dictation come back
    /// `incomplete: max_output_tokens` with nothing written.
    func testUnsetEffortStillReservesHeadroom() {
        XCTAssertGreaterThan(OpenAIBudget.reasoningHeadroom(effort: ""), 0)
    }

    /// Minimal still emits reasoning tokens — fewer, not none.
    func testMinimalReservesSomething() {
        XCTAssertGreaterThan(OpenAIBudget.reasoningHeadroom(effort: "minimal"), 0)
    }

    func testHeadroomGrowsWithEffort() {
        let minimal = OpenAIBudget.reasoningHeadroom(effort: "minimal")
        let low = OpenAIBudget.reasoningHeadroom(effort: "low")
        let high = OpenAIBudget.reasoningHeadroom(effort: "high")
        XCTAssertLessThan(minimal, low)
        XCTAssertLessThan(low, high)
    }

    /// An unrecognised value must not fall through to zero.
    func testUnknownEffortIsTreatedAsTheDefault() {
        XCTAssertEqual(
            OpenAIBudget.reasoningHeadroom(effort: "banana"),
            OpenAIBudget.reasoningHeadroom(effort: "")
        )
    }
}

final class ScreenReaderFilterTests: XCTestCase {
    /// A container states the whole message ("Sara: …") and its leaves restate
    /// the pieces. Keeping the longer one keeps the attribution.
    func testContainedLinesAreDropped() {
        let kept = ScreenReader.dropContainedLines([
            "Sara Rekvik: Kvarstår det vad vi vet? Today at 10:23",
            "Kvarstår det vad vi vet?",
            "Something else entirely",
        ])
        XCTAssertEqual(kept, [
            "Sara Rekvik: Kvarstår det vad vi vet? Today at 10:23",
            "Something else entirely",
        ])
    }

    /// "Yes" is a substring of "Yesterday at 3:27" and is not the same
    /// statement, so short lines are never dropped for being contained.
    func testShortLinesSurviveContainment() {
        let kept = ScreenReader.dropContainedLines(["Yesterday at 3:27 PM", "Yes"])
        XCTAssertEqual(kept, ["Yesterday at 3:27 PM", "Yes"])
    }

    func testReadingOrderIsPreserved() {
        let kept = ScreenReader.dropContainedLines(["first line here", "second line here", "third"])
        XCTAssertEqual(kept, ["first line here", "second line here", "third"])
    }

    /// Instructions meant for screen-reader users read to a language model as
    /// something it is being asked to do.
    func testAccessibilityHintsAreStripped() {
        XCTAssertEqual(
            ScreenReader.stripAccessibilityHints(
                "Monday, July 13th Press enter to select a date to jump to."
            ),
            "Monday, July 13th"
        )
        XCTAssertEqual(ScreenReader.stripAccessibilityHints("Just text"), "Just text")
    }

    /// Password managers are never read, whatever the settings say.
    func testPasswordManagersAreExcluded() {
        for name in ["1Password", "Bitwarden", "Keychain Access"] {
            let target = AppTarget(pid: 1, name: name, bundleID: nil)
            XCTAssertTrue(ScreenReader.isExcluded(target), name)
        }
        XCTAssertFalse(
            ScreenReader.isExcluded(AppTarget(pid: 1, name: "Mail", bundleID: "com.apple.mail"))
        )
    }

    /// A renamed or localised window title slips past the name fragment; the
    /// bundle id it ships under does not.
    func testPasswordManagersAreExcludedByBundleIDAlone() {
        let target = AppTarget(pid: 1, name: "Lösenord", bundleID: "com.1password.1password")
        XCTAssertTrue(ScreenReader.isExcluded(target))
    }

    /// Every built-in exclusion has to be showable in settings — a name a person
    /// recognises, and at least one id to resolve an icon from.
    func testBuiltInExclusionsArePresentable() {
        for entry in ScreenReader.alwaysExcluded {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.bundleIDs.isEmpty, entry.name)
            XCTAssertTrue(
                ScreenReader.isExcluded(
                    AppTarget(pid: 1, name: entry.name, bundleID: entry.bundleIDs[0])
                ),
                entry.name
            )
        }
    }

    func testSecureTextFieldsAreNeverDescendedInto() {
        XCTAssertTrue(ScreenReader.skippedRoles.contains("AXSecureTextField"))
    }

    func testUserExcludedBundleIDsAreHonoured() {
        var settings = SquawkSettings.default
        settings.excludedBundleIDs = ["com.example.Private"]
        XCTAssertTrue(settings.isExcluded(bundleID: "com.example.private"))
        XCTAssertFalse(settings.isExcluded(bundleID: "com.apple.mail"))
        XCTAssertFalse(settings.isExcluded(bundleID: nil))
    }

    /// The picker takes the same `com.example.App*` a style profile takes, so
    /// excluding an app has to catch its helper processes the same way.
    func testExcludedBundleIDsHonourWildcards() {
        var settings = SquawkSettings.default
        settings.excludedBundleIDs = ["com.google.Chrome*"]
        XCTAssertTrue(settings.isExcluded(bundleID: "com.google.Chrome"))
        XCTAssertTrue(settings.isExcluded(bundleID: "com.google.Chrome.helper"))
        XCTAssertFalse(settings.isExcluded(bundleID: "com.google.Drive"))
    }
}
