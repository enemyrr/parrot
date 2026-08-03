import CoreGraphics
import XCTest

@testable import parrot

/// Turning a written name into the words somebody says for it. Everything
/// downstream is a phrase match against these, so a wrong split here is a tag
/// that silently never fires.
final class SpokenFormTests: XCTestCase {
    func testSplitsCamelCase() {
        XCTAssertEqual(SpokenForm.phrase("authProvider"), "auth provider")
        XCTAssertEqual(SpokenForm.phrase("AuthProvider"), "auth provider")
        XCTAssertEqual(SpokenForm.phrase("useEffect"), "use effect")
    }

    /// An uppercase run ends where the next word's lowercase begins, so an
    /// acronym stays one word instead of becoming "h t t p".
    func testKeepsAcronymsWhole() {
        XCTAssertEqual(SpokenForm.phrase("HTTPClient"), "http client")
        XCTAssertEqual(SpokenForm.phrase("parseURLPath"), "parse url path")
    }

    func testSplitsSeparators() {
        XCTAssertEqual(SpokenForm.phrase("eng-parrot"), "eng parrot")
        XCTAssertEqual(SpokenForm.phrase("sara.rekvik"), "sara rekvik")
        XCTAssertEqual(SpokenForm.phrase("read_window_text"), "read window text")
    }

    /// All three get said, so all three are matched. Dropping the bare stem
    /// would miss the most common one by far.
    /// A terminal has no trigger word to protect the match, so the bare stem is
    /// dropped: rewriting "auth provider" into a filename mid-sentence would
    /// corrupt an ordinary sentence.
    func testUntriggeredFilenameFormsDropTheBareStem() {
        let forms = SpokenForm.untriggeredFilenameForms("AuthProvider.tsx")
        XCTAssertTrue(forms.contains("auth provider tsx"))
        XCTAssertTrue(forms.contains("auth provider dot tsx"))
        XCTAssertFalse(forms.contains("auth provider"))
    }

    /// "slash" is what makes a branch name safe to match without a trigger — it
    /// is not a word anyone says by accident.
    func testPathPhraseSpellsTheSlash() {
        XCTAssertEqual(
            SpokenForm.pathPhrase("feature/roster-reader"), "feature slash roster reader"
        )
    }

    func testFilenameGetsEveryFormPeopleSay() {
        let forms = SpokenForm.filenameForms("AuthProvider.tsx")
        XCTAssertTrue(forms.contains("auth provider tsx"))
        XCTAssertTrue(forms.contains("auth provider"))
        XCTAssertTrue(forms.contains("auth provider dot tsx"))
    }
}

/// The string-level rules the classifiers are built out of.
final class RosterTextTests: XCTestCase {
    func testTrimsUnreadCountsAndPresence() {
        XCTAssertEqual(RosterText.trimDecorations("general, 3 unread messages"), "general")
        XCTAssertEqual(RosterText.trimDecorations("Sara Rekvik (away)"), "Sara Rekvik")
    }

    func testTrimsScreenReaderHints() {
        XCTAssertEqual(
            RosterText.trimDecorations("Monday, July 13th Press enter to select a date"),
            "Monday"
        )
    }

    func testPersonNamesAreCapitalisedWords() {
        XCTAssertTrue(RosterText.looksLikePersonName("Sara Rekvik"))
        XCTAssertTrue(RosterText.looksLikePersonName("Jean-Luc Picard"))
        XCTAssertTrue(RosterText.looksLikePersonName("Andreas"))
    }

    /// The false positives that would otherwise become `@mentions`. A mention
    /// notifies a real person, so this rule is deliberately strict.
    func testRejectsThingsThatAreNotNames() {
        XCTAssertFalse(RosterText.looksLikePersonName("the deploy is green"))
        XCTAssertFalse(RosterText.looksLikePersonName("PAR-142"))
        XCTAssertFalse(RosterText.looksLikePersonName("general"))
        XCTAssertFalse(RosterText.looksLikePersonName("Four Words In A Row"))
    }

    func testRecognisesFilenames() {
        XCTAssertTrue(RosterText.looksLikeFilename("AuthProvider.tsx"))
        XCTAssertTrue(RosterText.looksLikeFilename("settings.local.json"))
        XCTAssertFalse(RosterText.looksLikeFilename("Makefile"))
        XCTAssertFalse(RosterText.looksLikeFilename("some sentence.that ends"))
        XCTAssertFalse(RosterText.looksLikeFilename(".tsx"))
    }

    /// Shape and length together: below six characters the shape rules stop
    /// telling identifiers apart from noise.
    func testIdentifiersNeedShapeAndLength() {
        XCTAssertEqual(RosterText.identifiers(in: "let authProvider = 1"), ["authProvider"])
        XCTAssertEqual(RosterText.identifiers(in: "read_window_text()"), ["read_window_text"])
        XCTAssertTrue(RosterText.identifiers(in: "the quick brown fox").isEmpty)
        XCTAssertTrue(RosterText.identifiers(in: "isOn = true").isEmpty)
        // All-caps is a constant; splitting it gives a spoken form nobody says.
        XCTAssertTrue(RosterText.identifiers(in: "MAX_RETRIES").isEmpty)
    }

    /// Every VS Code fork keeps its buffer off the accessibility tree until
    /// screen-reader mode is on, so the integration finds filenames and no
    /// identifiers. Saying so is the difference between a limitation and a bug.
    func testDetectsABlockedEditorBuffer() {
        let blocked = RosterScan(
            windowFrame: nil, windowTitle: nil,
            nodes: [.init(
                text: "The editor is not accessible at this time. To enable screen reader "
                    + "optimized mode, use ⇧⌥F1",
                role: "AXTextArea", frame: nil
            )]
        )
        XCTAssertNotNil(RosterText.editorAccessNote(in: blocked))

        let fine = RosterScan(
            windowFrame: nil, windowTitle: nil,
            nodes: [.init(text: "const authProvider = 1", role: "AXTextArea", frame: nil)]
        )
        XCTAssertNil(RosterText.editorAccessNote(in: fine))
    }

    func testTitlesAreNotSentences() {
        XCTAssertTrue(RosterText.looksLikeTitle("Architecture notes"))
        XCTAssertTrue(RosterText.looksLikeTitle("Q3 planning"))
        XCTAssertFalse(RosterText.looksLikeTitle("We shipped it. Finally."))
        XCTAssertFalse(RosterText.looksLikeTitle("ok"))
    }

    func testBasename() {
        XCTAssertEqual(RosterText.basename("src/app/page.tsx"), "page.tsx")
        XCTAssertEqual(RosterText.basename("page.tsx"), "page.tsx")
    }

    /// Shell output is full of things wrapped in brackets and quotes, and full
    /// of things that are not names at all.
    func testShellTokensStripWrappersAndDropURLs() {
        let tokens = RosterText.shellTokens(in: "(main) 'RosterReader.swift', https://x.com/y")
        XCTAssertTrue(tokens.contains("main"))
        XCTAssertTrue(tokens.contains("RosterReader.swift"))
        XCTAssertFalse(tokens.contains { $0.contains("http") })
    }

    /// This becomes a rewrite rule with no trigger word, so the bar is high.
    func testBranchNamesNeedASlashAndNoExtension() {
        XCTAssertTrue(RosterText.looksLikeBranch("feature/roster-reader"))
        XCTAssertTrue(RosterText.looksLikeBranch("release/2026-08"))
        XCTAssertFalse(RosterText.looksLikeBranch("main"))
        XCTAssertFalse(RosterText.looksLikeBranch("src/index.ts"))
        XCTAssertFalse(RosterText.looksLikeBranch("/absolute/path"))
    }

    func testFindsIssueKeys() {
        XCTAssertEqual(RosterText.issueKeys(in: "PAR-142 is blocked by ENG-7"), ["PAR-142", "ENG-7"])
        XCTAssertTrue(RosterText.issueKeys(in: "utf-8 and covid-19").isEmpty)
    }
}

/// The classifiers, against the scans they were written for.
final class AppIntegrationTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1400, height: 900)

    private func scan(
        sidebar: [String] = [],
        main: [String] = [],
        top: [String] = [],
        title: String? = nil
    ) -> RosterScan {
        var nodes: [RosterScan.Node] = []
        for (index, text) in sidebar.enumerated() {
            nodes.append(.init(
                text: text, role: "AXStaticText",
                frame: CGRect(x: 40, y: 200 + index * 24, width: 200, height: 20)
            ))
        }
        for (index, text) in top.enumerated() {
            nodes.append(.init(
                text: text, role: "AXStaticText",
                frame: CGRect(x: 600 + index * 120, y: 40, width: 110, height: 20)
            ))
        }
        for (index, text) in main.enumerated() {
            nodes.append(.init(
                text: text, role: "AXStaticText",
                frame: CGRect(x: 600, y: 200 + index * 40, width: 700, height: 30)
            ))
        }
        return RosterScan(windowFrame: window, windowTitle: title, nodes: nodes)
    }

    // MARK: - Chat

    func testFindsChannelsInTheSidebar() {
        let entities = AppIntegration.classifyChat(scan(
            sidebar: ["general", "eng-parrot", "Channels", "Direct messages"]
        ))
        let channels = entities.filter { $0.kind == .channel }.map(\.literal)
        XCTAssertEqual(channels, ["#general", "#eng-parrot"])
    }

    /// Section headers and app rows are capitalised; channel names are one
    /// lowercase token. That single rule keeps the sidebar's furniture out.
    func testSectionHeadersAreNotChannels() {
        let entities = AppIntegration.classifyChat(scan(sidebar: ["Threads", "Huddles", "Apps"]))
        XCTAssertTrue(entities.filter { $0.kind == .channel }.isEmpty)
    }

    /// The strongest person signal there is: Slack labels each message row
    /// "Name: …the message… Today at 10:23".
    func testFindsPeopleFromMessageRows() {
        let entities = AppIntegration.classifyChat(scan(main: [
            "Sara Rekvik: kvarstår det vad vi vet? Today at 10:23",
            "Andreas Enemyr: jag kollar på det Today at 10:25",
        ]))
        XCTAssertEqual(entities.filter { $0.kind == .person }.map(\.literal), ["@Sara", "@Andreas"])
    }

    /// A timestamp splits on a colon too, and a bare label is not a post.
    func testDoesNotTakeTimestampsAsSpeakers() {
        let entities = AppIntegration.classifyChat(scan(main: ["10:23", "Today at 10:23"]))
        XCTAssertTrue(entities.filter { $0.kind == .person }.isEmpty)
    }

    /// The first name alone is offered as a spoken form only when it isn't also
    /// an ordinary word — otherwise "look at mark's PR" becomes a mention.
    func testCommonWordFirstNamesGetNoBareForm() {
        let entities = AppIntegration.classifyChat(scan(main: [
            "Mark Andersson: shipping it Today at 09:00",
            "Sara Rekvik: nice Today at 09:01",
        ]))
        let mark = entities.first { $0.literal == "@Mark" }
        let sara = entities.first { $0.literal == "@Sara" }
        XCTAssertEqual(mark?.spokenForms, ["mark andersson"])
        XCTAssertEqual(sara?.spokenForms, ["sara rekvik", "sara"])
    }

    // MARK: - Editors

    func testFindsFilesFromTitleAndTabs() {
        let entities = AppIntegration.classifyEditor(scan(
            sidebar: ["RosterReader.swift"],
            top: ["AuthProvider.tsx", "index.ts"],
            title: "AuthProvider.tsx — parrot"
        ))
        let files = Set(entities.filter { $0.kind == .file }.map(\.literal))
        XCTAssertEqual(files, ["@AuthProvider.tsx", "@index.ts", "@RosterReader.swift"])
    }

    /// A hyphen is a filename character. Splitting the title on it would turn
    /// "roster-command.swift" into a file called "command.swift" that isn't
    /// there — and lose the one that is.
    func testAHyphenatedFilenameSurvivesTheTitleSplit() {
        let entities = AppIntegration.classifyEditor(scan(title: "roster-command.swift — parrot"))
        let files = entities.filter { $0.kind == .file }.map(\.literal)
        XCTAssertEqual(files, ["@roster-command.swift"])
    }

    /// The space-padded hyphen VS Code puts between title segments still splits.
    func testASpacedHyphenStillSeparatesTitleSegments() {
        let entities = AppIntegration.classifyEditor(scan(title: "index.ts - parrot"))
        let files = entities.filter { $0.kind == .file }.map(\.literal)
        XCTAssertEqual(files, ["@index.ts"])
    }

    // MARK: - Terminal

    /// Everything a terminal produces is a `.symbol`: no sigil and no trigger,
    /// because a shell has nothing to link.
    func testTerminalFindsFilesAndBranchesWithNoSigil() {
        let entities = AppIntegration.classifyTerminal(scan(main: [
            "~/Developer/parrot on feature/roster-reader",
            "swift build Sources/parrot/Context/RosterReader.swift",
        ]))
        XCTAssertTrue(entities.allSatisfy { $0.kind == .symbol })
        let literals = Set(entities.map(\.literal))
        XCTAssertTrue(literals.contains("RosterReader.swift"))
        XCTAssertTrue(literals.contains("feature/roster-reader"))
        XCTAssertFalse(literals.contains { $0.hasPrefix("@") })
    }

    /// The end-to-end shape of the terminal case: the extension has to be said,
    /// so an ordinary sentence containing the stem is untouched.
    func testTerminalFilenamesNeedTheExtensionSpoken() {
        let entities = AppIntegration.classifyTerminal(scan(main: [
            "open RosterReader.swift", "vim RosterReader.swift", "cat AppRoster.swift",
        ]))
        var settings = IntegrationSettings.default
        settings.enabled = true
        let roster = AppRoster(
            integrationID: "terminal", app: "Terminal", bundleID: nil, entities: entities,
            nodes: 10, elapsed: 0.1, truncated: false, unavailable: nil
        )
        let tagger = EntityTagger(roster: roster, settings: settings)
        XCTAssertEqual(tagger.apply(to: "open roster reader dot swift"), "open RosterReader.swift")
        XCTAssertEqual(tagger.apply(to: "ask the roster reader about it"),
                       "ask the roster reader about it")
    }

    // MARK: - Notion

    func testNotionTakesPagesFromTheSidebar() {
        let entities = AppIntegration.classifyNotion(scan(
            sidebar: ["Architecture notes", "Q3 planning", "We shipped it. Finally."]
        ))
        let pages = Set(entities.filter { $0.kind == .file }.map(\.literal))
        XCTAssertEqual(pages, ["@Architecture notes", "@Q3 planning"])
    }

    /// Notion's picker matches on full display names, so unlike Slack the whole
    /// name goes in. And a name has to repeat — a Notion page body is full of
    /// capitalised phrases that are not people.
    func testNotionPeopleNeedToRepeatAndKeepTheirFullName() {
        let entities = AppIntegration.classifyNotion(scan(main: [
            "Sara Rekvik", "Sara Rekvik", "Capital Expenditure Review",
        ]))
        XCTAssertEqual(entities.filter { $0.kind == .person }.map(\.literal), ["@Sara Rekvik"])
    }

    /// Frequency is what keeps one-off noise out of a table that becomes
    /// rewrite rules.
    func testSymbolsNeedToAppearTwice() {
        let entities = AppIntegration.classifyEditor(scan(main: [
            "const authProvider = useContext(ctx)",
            "return authProvider.session",
            "oneOffThing()",
        ]))
        let symbols = entities.filter { $0.kind == .symbol }.map(\.literal)
        XCTAssertEqual(symbols, ["authProvider"])
    }

    // MARK: - Obsidian

    /// Obsidian's literal is a wiki link, and the brackets are for the app.
    /// A hint list is not a place for punctuation — the decoder and the cleaner
    /// want the title.
    func testObsidianWikiLinkBracketsStayOutOfTheVocabulary() {
        let entity = AppEntity(
            kind: .file,
            literal: "[[Architecture notes]]",
            spokenForms: ["architecture notes"]
        )
        XCTAssertEqual(entity.bareLiteral, "Architecture notes")
    }
}

/// The rewrite itself. This is the part that puts characters in someone's
/// message, so the tests are as much about what it refuses to do.
final class EntityTaggerTests: XCTestCase {
    private func roster(_ entities: [AppEntity]) -> AppRoster {
        AppRoster(
            integrationID: "slack", app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            entities: entities, nodes: 100, elapsed: 0.1, truncated: false, unavailable: nil
        )
    }

    private var settings: IntegrationSettings {
        var settings = IntegrationSettings.default
        settings.enabled = true
        return settings
    }

    private var channel: AppEntity {
        AppEntity(kind: .channel, literal: "#eng-parrot", spokenForms: ["eng parrot"])
    }

    private var person: AppEntity {
        AppEntity(kind: .person, literal: "@Sara", spokenForms: ["sara rekvik", "sara"])
    }

    func testTagsAChannel() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(
            tagger.apply(to: "Post it in hashtag eng parrot when you're done"),
            "Post it in #eng-parrot when you're done"
        )
    }

    /// The transcriber splits it about half the time.
    func testHashTagSplitInTwoStillMatches() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(tagger.apply(to: "in hash tag eng parrot"), "in #eng-parrot")
    }

    func testTagsAPersonByFullNameAndFirstName() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(tagger.apply(to: "ask at sara rekvik"), "ask @Sara")
        XCTAssertEqual(tagger.apply(to: "ask at sara about it"), "ask @Sara about it")
    }

    /// The trigger word is consumed. "hashtag #eng-parrot" would be typed
    /// literally into the message.
    func testTriggerWordIsConsumed() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertFalse(tagger.apply(to: "in hashtag eng parrot").contains("hashtag"))
        XCTAssertFalse(tagger.apply(to: "ask at sara rekvik").contains(" at "))
    }

    /// The whole safety argument in one test: nothing fires without the trigger
    /// word, so an ordinary sentence about Sara stays an ordinary sentence.
    func testNothingFiresWithoutTheTriggerWord() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(
            tagger.apply(to: "sara rekvik said the eng parrot rollout is fine"),
            "sara rekvik said the eng parrot rollout is fine"
        )
    }

    /// The loose spacing between a key's words is for a transcriber's stray
    /// comma, not for two sentences. "we're at. Sara will" is a full stop
    /// followed by a name, and tagging across it would @-mention a real person
    /// out of ordinary prose.
    func testATriggerDoesNotReachAcrossASentenceEnd() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(
            tagger.apply(to: "That's where we're at. Sara will follow up."),
            "That's where we're at. Sara will follow up."
        )
        XCTAssertEqual(tagger.apply(to: "ask at\nsara about it"), "ask at\nsara about it")
    }

    /// What the loose spacing is actually for still works.
    func testACommaBetweenTheWordsStillMatches() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(tagger.apply(to: "post in hashtag, eng parrot"), "post in #eng-parrot")
    }

    /// A name that was never on screen cannot come out, because there is no
    /// model in this path to invent one.
    func testAnUnknownNameIsLeftAlone() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertEqual(tagger.apply(to: "ask at magnus about it"), "ask at magnus about it")
    }

    /// One stray label is not a roster. Below the floor the whole thing is
    /// discarded rather than half-applied.
    func testATinyRosterIsDiscarded() {
        let tagger = EntityTagger(roster: roster([channel]), settings: settings)
        XCTAssertTrue(tagger.isEmpty)
        XCTAssertEqual(tagger.apply(to: "in hashtag eng parrot"), "in hashtag eng parrot")
    }

    func testAnUnusableRosterTagsNothing() {
        let empty = AppRoster.failed(
            .nothingFound, integrationID: "slack", app: "Slack", bundleID: nil
        )
        XCTAssertTrue(EntityTagger(roster: empty, settings: settings).isEmpty)
        XCTAssertTrue(EntityTagger(roster: nil, settings: settings).isEmpty)
    }

    func testTheMasterSwitchStopsEverything() {
        var off = settings
        off.enabled = false
        XCTAssertTrue(EntityTagger(roster: roster([channel, person]), settings: off).isEmpty)
    }

    func testAnAppSwitchedOffTagsNothing() {
        var off = settings
        off.setEnabled(false, for: "slack")
        XCTAssertTrue(EntityTagger(roster: roster([channel, person]), settings: off).isEmpty)
    }

    /// Symbols have no trigger word, so they are the one rewrite that can fire
    /// on a sentence that meant the English words — and the one with its own
    /// switch.
    func testSymbolsRewriteWithoutATriggerAndCanBeSwitchedOff() {
        let symbols = [
            AppEntity(kind: .symbol, literal: "useEffect", spokenForms: ["use effect"]),
            AppEntity(kind: .symbol, literal: "authProvider", spokenForms: ["auth provider"]),
        ]
        var on = settings
        on.enabled = true
        XCTAssertEqual(
            EntityTagger(roster: roster(symbols), settings: on).apply(to: "wrap it in use effect"),
            "wrap it in useEffect"
        )

        var off = on
        off.spellSymbols = false
        XCTAssertEqual(
            EntityTagger(roster: roster(symbols), settings: off).apply(to: "wrap it in use effect"),
            "wrap it in use effect"
        )
    }

    /// The names go upstream as hints, because a rule for "eng parrot" never
    /// fires if the decoder wrote "ang parrot".
    func testVocabularyCarriesTheBareNames() {
        let tagger = EntityTagger(roster: roster([channel, person]), settings: settings)
        XCTAssertTrue(tagger.vocabulary.contains("eng-parrot"))
        XCTAssertTrue(tagger.vocabulary.contains("Sara"))
        XCTAssertFalse(tagger.vocabulary.contains("#eng-parrot"))
    }
}

/// The failsafe: an integration that stops working has to stop costing
/// anything, and has to say so.
@MainActor
final class IntegrationMonitorTests: XCTestCase {
    private let integration = AppIntegration.slack
    private let pid: pid_t = 4242

    private func emptyRoster() -> AppRoster {
        .failed(.nothingFound, integrationID: "slack", app: "Slack", bundleID: nil)
    }

    private func goodRoster() -> AppRoster {
        AppRoster(
            integrationID: "slack", app: "Slack", bundleID: nil,
            entities: [
                AppEntity(kind: .channel, literal: "#a", spokenForms: ["a"]),
                AppEntity(kind: .channel, literal: "#b", spokenForms: ["b"]),
            ],
            nodes: 10, elapsed: 0.1, truncated: false, unavailable: nil
        )
    }

    func testGivesUpAfterRepeatedEmptyReads() {
        let monitor = IntegrationMonitor()
        for _ in 0..<IntegrationMonitor.failureLimit {
            XCTAssertTrue(monitor.shouldRead(integration, pid: pid))
            monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        }
        XCTAssertFalse(monitor.shouldRead(integration, pid: pid))
        XCTAssertEqual(
            monitor.availability(for: integration, settings: onSettings), .gaveUp
        )
    }

    /// Permission not granted yet says nothing about whether the integration
    /// works. Counting it would leave the thing dead after the user granted it.
    func testAnEnvironmentalFailureDoesNotCountTowardGivingUp() {
        let monitor = IntegrationMonitor()
        for reason in [IntegrationUnavailable.noAccessibility, .noWindow] {
            for _ in 0..<IntegrationMonitor.failureLimit {
                monitor.record(
                    .failed(reason, integrationID: "slack", app: "Slack", bundleID: nil),
                    integrationID: integration.id,
                    pid: pid
                )
            }
        }
        XCTAssertEqual(monitor.state(for: integration.id).consecutiveFailures, 0)
        XCTAssertTrue(monitor.shouldRead(integration, pid: pid))
    }

    /// One empty read is an editor with no file open, not a broken integration.
    func testOneEmptyReadIsNotEnough() {
        let monitor = IntegrationMonitor()
        monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        XCTAssertTrue(monitor.shouldRead(integration, pid: pid))
    }

    func testASuccessfulReadClearsTheCount() {
        let monitor = IntegrationMonitor()
        monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        monitor.record(goodRoster(), integrationID: integration.id, pid: pid)
        XCTAssertEqual(monitor.state(for: integration.id).consecutiveFailures, 0)
        XCTAssertTrue(monitor.shouldRead(integration, pid: pid))
    }

    /// The app restarting is the most likely thing to have fixed it, so a new
    /// pid buys another go without the user doing anything.
    func testARestartGetsAnotherChance() {
        let monitor = IntegrationMonitor()
        for _ in 0..<IntegrationMonitor.failureLimit {
            monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        }
        XCTAssertFalse(monitor.shouldRead(integration, pid: pid))
        XCTAssertTrue(monitor.shouldRead(integration, pid: pid + 1))
    }

    func testResetClearsTheVerdict() {
        let monitor = IntegrationMonitor()
        for _ in 0..<IntegrationMonitor.failureLimit {
            monitor.record(emptyRoster(), integrationID: integration.id, pid: pid)
        }
        monitor.reset()
        XCTAssertTrue(monitor.shouldRead(integration, pid: pid))
        XCTAssertNil(monitor.availability(for: integration, settings: onSettings))
    }

    func testAnAppSwitchedOffReportsOff() {
        let monitor = IntegrationMonitor()
        var settings = onSettings
        settings.setEnabled(false, for: integration.id)
        XCTAssertEqual(monitor.availability(for: integration, settings: settings), .off)
    }

    private var onSettings: IntegrationSettings {
        var settings = IntegrationSettings.default
        settings.enabled = true
        return settings
    }
}

/// Bundle id routing. Every integration has to claim its apps and nobody
/// else's.
final class IntegrationRoutingTests: XCTestCase {
    func testRoutesKnownApps() {
        XCTAssertEqual(AppIntegrations.integration(for: "com.tinyspeck.slackmacgap")?.id, "slack")
        XCTAssertEqual(
            AppIntegrations.integration(for: "com.todesktop.230313mzl4w4u92")?.id, "cursor"
        )
        XCTAssertEqual(AppIntegrations.integration(for: "md.obsidian")?.id, "obsidian")
    }

    func testUnknownAppsGetNothing() {
        XCTAssertNil(AppIntegrations.integration(for: "com.apple.mail"))
        XCTAssertNil(AppIntegrations.integration(for: nil))
    }

    func testIDsAreUnique() {
        let ids = AppIntegrations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Two integrations claiming one bundle id means the first one silently
    /// wins forever.
    func testNoBundleIDIsClaimedTwice() {
        var seen = Set<String>()
        for integration in AppIntegrations.all {
            for bundleID in integration.bundleIDs {
                XCTAssertTrue(
                    seen.insert(bundleID.lowercased()).inserted,
                    "\(bundleID) is claimed by more than one integration"
                )
            }
        }
    }
}
