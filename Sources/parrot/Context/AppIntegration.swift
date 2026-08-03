import CoreGraphics
import Foundation

/// What one look at a window produced, before anything decided what it meant.
///
/// Deliberately flat and geometric. Every integration in here is a guess about
/// how one app lays its window out, and geometry is the only thing those apps
/// agree on: a sidebar is on the left in Slack and in VS Code and in Discord,
/// whatever their accessibility trees call it.
struct RosterScan: Equatable {
    struct Node: Equatable {
        let text: String
        let role: String
        /// Screen-absolute. Nil for an app that publishes no geometry, which
        /// costs that node every zone test — it is kept, and only the rules
        /// that need a position skip it.
        let frame: CGRect?
    }

    let windowFrame: CGRect?
    let windowTitle: String?
    let nodes: [Node]

    /// Where the left rail ends. A fraction of the width, capped: Slack's
    /// sidebar is ~260pt and VS Code's explorer ~300pt whether the window is
    /// 1000pt wide or 3000, so a pure fraction reaches into the message list on
    /// a big display and a pure constant misses it on a small one.
    private var railEdge: CGFloat? {
        guard let windowFrame, windowFrame.width > 0 else { return nil }
        return windowFrame.minX + min(windowFrame.width * 0.32, 420)
    }

    /// Whether one node sits in the rail. The zone test itself, so the
    /// diagnostics in `parrot roster --nodes` can label a node the same way the
    /// classifiers sorted it.
    func isInLeftRail(_ node: Node) -> Bool {
        guard let railEdge, let frame = node.frame else { return false }
        return frame.minX < railEdge
    }

    /// Nodes in the left rail.
    func leftRail() -> [Node] {
        nodes.filter(isInLeftRail)
    }

    /// Nodes outside the left rail — the message list, the editor, the canvas.
    func mainArea() -> [Node] {
        // A node with no frame could be anywhere; the main area is the bigger
        // half, so it is the better place to guess — and with no window
        // geometry at all, everything is main.
        guard railEdge != nil else { return nodes }
        return nodes.filter { !isInLeftRail($0) }
    }

    /// Nodes in the strip along the top — tab bars, breadcrumbs. AX geometry is
    /// top-left origin, so this is the *small* y end.
    func topBand(height: CGFloat = 130) -> [Node] {
        guard let windowFrame else { return [] }
        return nodes.filter { node in
            guard let frame = node.frame else { return false }
            return frame.minY < windowFrame.minY + height
        }
    }
}

/// One app parrot knows how to read names out of.
///
/// A closure rather than a protocol: every one of these is a handful of
/// heuristics over the same `RosterScan`, and a protocol with one method per
/// conformer would be four files of ceremony around four functions.
struct AppIntegration: Identifiable {
    let id: String
    /// What the settings row calls it.
    let name: String
    let symbol: String
    /// Matched with `BundleIDPattern`, so a trailing `*` works.
    let bundleIDs: [String]
    /// The sentence under the name in settings. Says what it does in terms of
    /// what the user would say out loud.
    let blurb: String
    /// What it can find, for the row's summary.
    let kinds: [AppEntity.Kind]
    let classify: @Sendable (RosterScan) -> [AppEntity]

    func matches(_ bundleID: String) -> Bool {
        BundleIDPattern.matches(any: bundleIDs, bundleID)
    }
}

/// Every app with an integration, and the lookup from a bundle id to it.
enum AppIntegrations {
    static let all: [AppIntegration] = [
        .slack, .discord, .notion,
        .cursor, .windsurf, .antigravity, .vsCode, .xcode, .terminal,
        .linear, .obsidian,
    ]

    static func integration(for bundleID: String?) -> AppIntegration? {
        guard let bundleID else { return nil }
        return all.first { $0.matches(bundleID) }
    }

    static func integration(id: String) -> AppIntegration? {
        all.first { $0.id == id }
    }
}

// MARK: - Chat

extension AppIntegration {
    /// Slack.
    ///
    /// Channels are the case that genuinely works: `#eng-parrot` is one token,
    /// and Slack's composer turns typed `#eng-parrot` into a real channel link
    /// on send. People are the case that half works — see `chatPerson`.
    static let slack = AppIntegration(
        id: "slack",
        name: "Slack",
        symbol: "number",
        bundleIDs: ["com.tinyspeck.slackmacgap"],
        blurb: "Say “at” before someone's name to mention them, or “hashtag” before a "
            + "channel name to link it.",
        kinds: [.channel, .person],
        classify: { classifyChat($0) }
    )

    static let discord = AppIntegration(
        id: "discord",
        name: "Discord",
        symbol: "number",
        bundleIDs: ["com.hnc.Discord", "com.hnc.Discord*"],
        blurb: "Say “at” before a name or “hashtag” before a channel, the same as in Slack.",
        kinds: [.channel, .person],
        classify: { classifyChat($0) }
    )

    /// Channels out of the sidebar, people out of the message list.
    ///
    /// The message list is the better source for people by a wide margin: Slack
    /// labels each row "Sara Rekvik: …the message… Today at 10:23", so the name
    /// arrives already attached to evidence that this is a person who posts
    /// here. The sidebar mixes channels, DMs, apps and section headers with no
    /// role to tell them apart.
    static func classifyChat(_ scan: RosterScan) -> [AppEntity] {
        var entities: [AppEntity] = []
        var seen = Set<String>()

        for node in scan.leftRail() {
            let text = RosterText.trimDecorations(node.text)
            guard let channel = chatChannel(text) else { continue }
            guard seen.insert("#" + channel.lowercased()).inserted else { continue }
            entities.append(AppEntity(
                kind: .channel,
                literal: "#" + channel,
                spokenForms: [SpokenForm.phrase(channel)]
            ))
        }

        for node in scan.mainArea() {
            guard let name = chatSpeaker(node.text) else { continue }
            guard let person = chatPerson(name, seen: &seen) else { continue }
            entities.append(person)
        }

        // The sidebar's DM rows, only after the message list has had its say —
        // a name already found as a speaker is the one with evidence behind it.
        for node in scan.leftRail() {
            let text = RosterText.trimDecorations(node.text)
            guard RosterText.looksLikePersonName(text) else { continue }
            guard let person = chatPerson(text, seen: &seen) else { continue }
            entities.append(person)
        }

        return entities
    }

    /// A sidebar row that is a channel, or nil.
    ///
    /// Slack publishes these with or without the `#`, depending on where in the
    /// tree you catch them, so the sigil is evidence when present and never
    /// required.
    private static func chatChannel(_ text: String) -> String? {
        var name = text
        if name.hasPrefix("#") { name = String(name.dropFirst()) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, name.count <= 40 else { return nil }
        // Channel names are one lowercase token: letters, digits, dashes and
        // underscores, nothing else. That single rule is what keeps section
        // headers ("Channels", "Direct messages") and app rows out.
        guard name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        guard name.contains(where: \.isLetter) else { return nil }
        return name
    }

    /// "Sara Rekvik: kvarstår det vad vi vet? Today at 10:23" → "Sara Rekvik".
    private static func chatSpeaker(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        // There has to be a message after the name — a bare "Sara Rekvik:" is
        // as likely to be a label as a post, and a timestamp like "10:23"
        // splits on a colon too.
        guard text.index(after: colon) < text.endIndex else { return nil }
        guard RosterText.looksLikePersonName(head) else { return nil }
        return head
    }

    /// A display name as something that can be typed.
    ///
    /// **The known limit of this whole feature.** Slack mentions resolve on a
    /// handle, not a display name, and a plain-text `@Sara Rekvik` does not
    /// linkify — the space ends the token. So what goes in is `@Sara`: one
    /// token, which Slack's own autocomplete opens on and resolves when it is
    /// unique. Ambiguous first names need the user to pick from that popup,
    /// which is one keystroke and visible on screen, rather than parrot
    /// silently mentioning the wrong person.
    private static func chatPerson(_ displayName: String, seen: inout Set<String>) -> AppEntity? {
        let words = displayName.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first.count >= 2 else { return nil }
        let handle = "@" + first
        guard seen.insert(handle.lowercased()).inserted else { return nil }

        var forms = [SpokenForm.phrase(displayName)]
        // The first name on its own, but only when it isn't also an ordinary
        // word: "look at mark's PR" must not become a mention.
        if first.count >= 4, !RosterText.isCommonWord(first) {
            forms.append(SpokenForm.phrase(first))
        }
        return AppEntity(kind: .person, literal: handle, spokenForms: forms)
    }
}

// MARK: - Editors

extension AppIntegration {
    static let cursor = AppIntegration(
        id: "cursor",
        name: "Cursor",
        symbol: "chevron.left.forwardslash.chevron.right",
        bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor", "sh.cursor.Cursor"],
        blurb: "Uses what's open to tag files and spell identifiers while you code.",
        kinds: [.file, .symbol],
        classify: { classifyEditor($0) }
    )

    static let windsurf = AppIntegration(
        id: "windsurf",
        name: "Windsurf",
        symbol: "chevron.left.forwardslash.chevron.right",
        bundleIDs: ["com.exafunction.windsurf", "com.codeium.windsurf"],
        blurb: "Uses what's open to tag files and spell identifiers while you code.",
        kinds: [.file, .symbol],
        classify: { classifyEditor($0) }
    )

    static let antigravity = AppIntegration(
        id: "antigravity",
        name: "Antigravity",
        symbol: "chevron.left.forwardslash.chevron.right",
        bundleIDs: ["com.google.antigravity", "dev.antigravity.Antigravity"],
        blurb: "Uses what's open to tag files and spell identifiers while you code.",
        kinds: [.file, .symbol],
        classify: { classifyEditor($0) }
    )

    static let vsCode = AppIntegration(
        id: "vscode",
        name: "VS Code",
        symbol: "chevron.left.forwardslash.chevron.right",
        bundleIDs: ["com.microsoft.VSCode", "com.visualstudio.code.oss"],
        blurb: "Uses what's open to tag files and spell identifiers while you code.",
        kinds: [.file, .symbol],
        classify: { classifyEditor($0) }
    )

    /// Xcode. The one editor where the identifier half genuinely works.
    ///
    /// Every VS Code fork keeps its buffer off the accessibility tree until
    /// screen-reader mode is on — see `RosterText.blockedEditorMarker`. Xcode is
    /// native AppKit, so its source editor is a real `AXTextArea` that answers
    /// `AXStringForRange`, and `RosterReader.visibleText` gets the code on
    /// screen without asking the user to turn anything on.
    static let xcode = AppIntegration(
        id: "xcode",
        name: "Xcode",
        symbol: "hammer",
        bundleIDs: ["com.apple.dt.Xcode"],
        blurb: "Reads the source on screen, so type and function names land spelled right.",
        kinds: [.file, .symbol],
        classify: { classifyEditor($0) }
    )

    /// Files out of the tab bar, the explorer and the window title; identifiers
    /// out of the code that is actually visible.
    ///
    /// Every editor here is a VS Code fork, so this is one function with four
    /// bundle ids in front of it — which is also why the settings rows for
    /// Cursor, Windsurf and Antigravity say exactly the same thing.
    static func classifyEditor(_ scan: RosterScan) -> [AppEntity] {
        var entities: [AppEntity] = []
        var seen = Set<String>()

        func addFile(_ name: String) {
            let name = name.trimmingCharacters(in: .whitespaces)
            guard RosterText.looksLikeFilename(name) else { return }
            guard seen.insert(name.lowercased()).inserted else { return }
            entities.append(AppEntity(
                kind: .file,
                literal: "@" + name,
                spokenForms: SpokenForm.filenameForms(name)
            ))
        }

        // The window title first: "AuthProvider.tsx — parrot" names the file
        // being edited right now, which is the one most likely to be talked
        // about, and it costs one attribute read rather than a walk.
        // Dashes only, plus a space-padded hyphen: a bare "-" is a filename
        // character — splitting on it turns "roster-command.swift" into a file
        // called "command.swift" that doesn't exist.
        if let title = scan.windowTitle {
            let parts = title
                .split(whereSeparator: { $0 == "—" || $0 == "–" })
                .flatMap { $0.components(separatedBy: " - ") }
            for part in parts {
                addFile(part)
            }
        }
        for node in scan.topBand() { addFile(RosterText.trimDecorations(node.text)) }
        for node in scan.leftRail() { addFile(RosterText.trimDecorations(node.text)) }

        entities.append(contentsOf: symbols(in: scan.mainArea(), excluding: seen))
        return entities
    }

    /// Identifiers from the visible code, frequency-ranked.
    ///
    /// Two guards, and they carry the whole thing. **Shape**: an identifier has
    /// to be camelCase, PascalCase or snake_case — a bare lowercase word is
    /// indistinguishable from English, and half of what is on an editor's
    /// screen is comments and strings. **Frequency**: it has to appear at least
    /// twice. A symbol that occurs once is as likely to be noise as a name, and
    /// this list becomes rewrite rules — a wrong one silently corrupts a word
    /// the user actually said.
    static func symbols(in nodes: [RosterScan.Node], excluding seen: Set<String>) -> [AppEntity] {
        var counts: [String: Int] = [:]
        for node in nodes {
            for token in RosterText.identifiers(in: node.text) {
                counts[token, default: 0] += 1
            }
        }

        return counts
            .filter { $0.value >= 2 && !seen.contains($0.key.lowercased()) }
            .sorted { a, b in
                a.value == b.value ? a.key < b.key : a.value > b.value
            }
            .prefix(80)
            .map { token, _ in
                AppEntity(
                    kind: .symbol,
                    literal: token,
                    spokenForms: [SpokenForm.phrase(token)]
                )
            }
    }
}

// MARK: - Terminals

extension AppIntegration {
    /// Terminals, and the one integration with nothing to tag.
    ///
    /// A shell has no `@` and no `#` — there is nothing to link, so the trigger
    /// words would be typing punctuation into a command. What it has instead is
    /// the thing dictation is worst at: `RosterReader.swift` said out loud is
    /// "roster reader dot swift", and no decoder writes that as one PascalCase
    /// token unless it has been told the token exists. So everything here is a
    /// `.symbol` — no sigil, no trigger, pure spelling — and the scrollback in
    /// front of you is where the spellings come from.
    ///
    /// Which is also why this is the one that matters most for dictating into a
    /// coding agent: the paths you are about to talk about are on screen because
    /// you were just talking about them.
    static let terminal = AppIntegration(
        id: "terminal",
        name: "Terminal",
        symbol: "terminal",
        bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
            "com.github.wez.wezterm",
        ],
        blurb: "Picks filenames, paths and branch names out of the scrollback so they land "
            + "spelled right. Nothing is tagged — a shell has nothing to link.",
        kinds: [.symbol],
        classify: { classifyTerminal($0) }
    )

    static func classifyTerminal(_ scan: RosterScan) -> [AppEntity] {
        var entities: [AppEntity] = []
        var seen = Set<String>()
        /// Filename stems, kept out of the identifier pass below.
        ///
        /// Without this the rule above defeats itself: `RosterReader.swift`
        /// yields a file whose spoken form deliberately requires the extension,
        /// and then the identifier scanner finds `RosterReader` in the same
        /// text and adds "roster reader" back as a rewrite with nothing in
        /// front of it. Same token, two paths, opposite answers.
        var stems = Set<String>()

        for node in scan.nodes {
            for token in RosterText.shellTokens(in: node.text) {
                let name = RosterText.basename(token)
                if RosterText.looksLikeFilename(name) {
                    if let dot = name.lastIndex(of: ".") {
                        stems.insert(String(name[name.startIndex..<dot]).lowercased())
                    }
                    guard seen.insert(name.lowercased()).inserted else { continue }
                    entities.append(AppEntity(
                        kind: .symbol,
                        literal: name,
                        spokenForms: SpokenForm.untriggeredFilenameForms(name)
                    ))
                } else if RosterText.looksLikeBranch(token) {
                    guard seen.insert(token.lowercased()).inserted else { continue }
                    entities.append(AppEntity(
                        kind: .symbol,
                        literal: token,
                        // "feature slash roster reader". The word "slash" is
                        // what makes this safe without a trigger — it is not a
                        // thing anyone says by accident.
                        spokenForms: [SpokenForm.pathPhrase(token)]
                    ))
                }
            }
        }

        entities.append(contentsOf: symbols(in: scan.nodes, excluding: seen.union(stems)))
        return entities
    }
}

// MARK: - Notes and issues

extension AppIntegration {
    /// Linear. Issue ids are the thing worth getting right — "PAR-142" spoken
    /// aloud is four syllables the transcriber has no reason to spell that way.
    static let linear = AppIntegration(
        id: "linear",
        name: "Linear",
        symbol: "checklist",
        bundleIDs: ["com.linear", "com.linear.linear", "com.linear.desktop"],
        blurb: "Picks up issue ids and project names off the board so they land spelled right.",
        kinds: [.symbol, .person],
        classify: { scan in
            var entities: [AppEntity] = []
            var seen = Set<String>()
            for node in scan.nodes {
                for id in RosterText.issueKeys(in: node.text) {
                    guard seen.insert(id.lowercased()).inserted else { continue }
                    entities.append(AppEntity(
                        kind: .symbol,
                        literal: id,
                        spokenForms: [SpokenForm.issueKey(id)]
                    ))
                }
            }
            return entities
        }
    )

    /// Notion. Pages and people, both reached with `@`.
    ///
    /// Different from Slack in one way that decides the design: Notion has no
    /// linkify-on-send. `@Sara Rekvik` typed as plain text stays plain text
    /// forever — what turns it into a mention is Notion's own picker, which
    /// opens on the `@` and filters on what follows. Since dictation types its
    /// output rather than pasting it (see `TextInjector.inject`), the picker
    /// does open, and it matches on full display names. So unlike Slack, the
    /// whole name goes in rather than the first token.
    static let notion = AppIntegration(
        id: "notion",
        name: "Notion",
        symbol: "doc.text",
        bundleIDs: ["notion.id"],
        blurb: "Say “at” before a page title or someone's name — Notion's own picker opens "
            + "on it and takes the rest.",
        kinds: [.file, .person],
        classify: { classifyNotion($0) }
    )

    static func classifyNotion(_ scan: RosterScan) -> [AppEntity] {
        var entities: [AppEntity] = []
        var seen = Set<String>()

        // The sidebar is a list of page titles, which is the cleanest source of
        // pages there is — the body of a page is full of headings that look
        // exactly like titles and are not.
        for node in scan.leftRail() {
            let title = RosterText.trimDecorations(node.text)
            guard RosterText.looksLikeTitle(title) else { continue }
            guard seen.insert(title.lowercased()).inserted else { continue }
            entities.append(AppEntity(
                kind: .file,
                literal: "@" + title,
                spokenForms: [SpokenForm.phrase(title)]
            ))
        }

        // A name that shows up more than once is a comment author or a person
        // property. One that shows up once is a capitalised phrase in the body
        // text — and Notion pages are full of those.
        var counts: [String: Int] = [:]
        for node in scan.mainArea() {
            let text = RosterText.trimDecorations(node.text)
            guard RosterText.looksLikePersonName(text) else { continue }
            counts[text, default: 0] += 1
        }
        for name in counts.filter({ $0.value >= 2 }).keys.sorted() {
            guard seen.insert("@" + name.lowercased()).inserted else { continue }
            entities.append(AppEntity(
                kind: .person,
                literal: "@" + name,
                spokenForms: [SpokenForm.phrase(name)]
            ))
        }

        return entities
    }

    /// Obsidian. Note titles, tagged with the wiki-link the app already uses.
    static let obsidian = AppIntegration(
        id: "obsidian",
        name: "Obsidian",
        symbol: "note.text",
        bundleIDs: ["md.obsidian"],
        blurb: "Say “at” before a note's title to link it.",
        kinds: [.file],
        classify: { scan in
            var entities: [AppEntity] = []
            var seen = Set<String>()
            for node in scan.leftRail() {
                let title = RosterText.trimDecorations(node.text)
                guard RosterText.looksLikeTitle(title) else { continue }
                guard seen.insert(title.lowercased()).inserted else { continue }
                entities.append(AppEntity(
                    kind: .file,
                    literal: "[[\(title)]]",
                    spokenForms: [SpokenForm.phrase(title)]
                ))
            }
            return entities
        }
    )
}

// MARK: - Text rules

/// The string-level rules the classifiers share.
///
/// Separated out because these are the parts worth testing on their own: every
/// one of them is a guess that can be checked against a literal string, where a
/// classifier can only be checked against a whole scan.
enum RosterText {
    /// Strips what apps hang off the end of a label: unread counts, presence,
    /// and the trailing hints `ScreenReader` already knows about.
    static func trimDecorations(_ raw: String) -> String {
        var text = ScreenReader.stripAccessibilityHints(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "general, 3 unread messages" — the comma is where the label stops
        // being a name and starts being a status.
        if let comma = text.firstIndex(of: ",") {
            text = String(text[text.startIndex..<comma])
        }
        // "Sara Rekvik (away)"
        if let paren = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<paren])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One to three capitalized words. Deliberately strict: this decides
    /// whether something becomes an `@mention`, and the cost of a false
    /// positive is pinging a real person.
    static func looksLikePersonName(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...3).contains(words.count) else { return false }
        guard text.count <= 48 else { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            // Letters, and the punctuation names actually contain. A word with
            // a digit or a symbol in it is an id, not a name.
            return word.allSatisfy { $0.isLetter || "'’-.".contains($0) }
        }
    }

    /// `AuthProvider.tsx`, `settings.local.json`, `Makefile` is not one.
    static func looksLikeFilename(_ text: String) -> Bool {
        guard text.count >= 3, text.count <= 64 else { return false }
        guard !text.contains(where: \.isWhitespace) else { return false }
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        let ext = text[text.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isLowercase || $0.isNumber })
        else { return false }
        let stem = text[text.startIndex..<dot]
        guard !stem.isEmpty else { return false }
        return stem.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// A page or note title: a phrase, not a sentence.
    ///
    /// Sentence punctuation is the tell. A sidebar row is "Architecture notes";
    /// anything with a full stop or a question mark in it is the document's
    /// contents having leaked into the rail.
    static func looksLikeTitle(_ text: String) -> Bool {
        guard text.count >= 3, text.count <= 60 else { return false }
        guard text.contains(where: \.isLetter) else { return false }
        return !text.contains(where: { ".?!;:".contains($0) })
    }

    /// The last path component. `src/app/page.tsx` → `page.tsx`.
    static func basename(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }

    /// Tokens in terminal output that might name something.
    ///
    /// Split on whitespace and stripped of the punctuation a shell wraps things
    /// in — quotes, brackets, the trailing comma of a list, the `(main)` of a
    /// prompt. Anything with a colon in it is dropped whole: that is a URL, a
    /// timestamp or a `file:line` compiler note, and none of them is a name.
    static func shellTokens(in text: String) -> [String] {
        guard text.count <= 8000 else { return [] }
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}'\"`,;*|<>"))
            guard token.count >= 3, token.count <= 120 else { continue }
            guard !token.contains(":") else { continue }
            guard let first = token.first, first.isLetter || first == "." || first == "/"
            else { continue }
            out.append(token)
        }
        return out
    }

    /// `feature/roster-reader`, `release/2026-08`. A path with no extension.
    ///
    /// Deliberately narrow, because this becomes a rewrite rule with no trigger
    /// word in front of it. The `/` is what earns it: the spoken form contains
    /// the word "slash", which nobody says by accident.
    static func looksLikeBranch(_ token: String) -> Bool {
        guard (4...60).contains(token.count) else { return false }
        guard token.contains("/"), !token.hasPrefix("/"), !token.hasSuffix("/") else { return false }
        guard let first = token.first, first.isLetter else { return false }
        // An extension means it is a path to a file, and the basename already
        // covers that case better.
        guard !looksLikeFilename(basename(token)) else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) }
    }

    /// camelCase, PascalCase and snake_case identifiers, six characters and up.
    ///
    /// The length floor is not arbitrary: below it the shape rules stop
    /// discriminating — "isOn" and "a_b" are identifiers by shape and noise by
    /// any other measure.
    /// The ceiling is a text area's worth, not a label's: a native editor
    /// publishes its visible source as one node, and that is exactly the node
    /// worth mining.
    static func identifiers(in text: String) -> [String] {
        guard text.count <= 8000 else { return [] }
        var out: [String] = []
        var current = ""

        func flush() {
            defer { current = "" }
            guard current.count >= 6, current.count <= 40 else { return }
            guard let first = current.first, first.isLetter else { return }
            let hasInnerUppercase = current.dropFirst().contains(where: \.isUppercase)
            let hasUnderscore = current.dropFirst().dropLast().contains("_")
            guard hasInnerUppercase || hasUnderscore else { return }
            // All-caps is a constant or an acronym, and splitting it into words
            // gives a spoken form nobody would ever say.
            guard current.contains(where: \.isLowercase) else { return }
            out.append(current)
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// `PAR-142`, `ENG-7`. Two to six uppercase letters, a dash, digits.
    static func issueKeys(in text: String) -> [String] {
        guard text.count <= 400 else { return [] }
        var out: [String] = []
        for token in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
            let parts = token.split(separator: "-")
            guard parts.count == 2 else { continue }
            let prefix = parts[0], number = parts[1]
            guard (2...6).contains(prefix.count), prefix.allSatisfy(\.isUppercase) else { continue }
            guard (1...6).contains(number.count), number.allSatisfy(\.isNumber) else { continue }
            out.append(String(token))
        }
        return out
    }

    /// What a VS Code fork puts in place of its editor contents when
    /// screen-reader mode is off — which is the default, in every fork.
    ///
    /// Found by walking one: the editor's `AXTextArea` holds this sentence
    /// instead of the code. So filenames, tabs and panels read fine and the
    /// buffer reads as nothing, and an integration that promised identifiers
    /// silently delivers none. Matched on a fragment rather than the whole
    /// string because the key hint at the end of it differs by version.
    static let blockedEditorMarker = "editor is not accessible"

    /// The sentence to show when that happens. Names the fix, because there is
    /// one and it is two settings deep.
    static func editorAccessNote(in scan: RosterScan) -> String? {
        let blocked = scan.nodes.contains { node in
            node.text.range(of: blockedEditorMarker, options: .caseInsensitive) != nil
        }
        guard blocked else { return nil }
        return "The editor's contents aren't on the accessibility tree, so filenames were "
            + "found and identifiers weren't. Turn on “Editor: Accessibility Support” in the "
            + "app's settings (or press ⇧⌥F1) if you want those too."
    }

    /// Words that are both ordinary English and plausible first names.
    ///
    /// Only ever consulted for the first-name-on-its-own spoken form of a
    /// person, which is the one place a match fires on a word the speaker
    /// almost certainly did not mean as a name.
    static let commonWords: Set<String> = [
        "will", "mark", "bill", "grace", "hope", "rose", "joy", "dawn", "frank", "drew",
        "chase", "ray", "jack", "sky", "page", "art", "may", "june", "sunny", "faith",
        "brook", "brooke", "summer", "autumn", "sterling", "rich", "young", "long",
        "king", "love", "reed", "wade", "victor", "major", "miles", "penny", "hunter",
        "carter", "parker", "cooper", "porter", "mason", "field", "moss", "gray", "grey",
        "north", "west", "east", "south", "price", "case", "story", "star",
    ]

    static func isCommonWord(_ word: String) -> Bool {
        commonWords.contains(word.lowercased())
    }
}

/// Turning a written name into the words somebody would say for it.
enum SpokenForm {
    /// "AuthProvider" → "auth provider". "eng-parrot" → "eng parrot".
    /// "sara.rekvik" → "sara rekvik".
    static func phrase(_ text: String) -> String {
        words(in: text).joined(separator: " ").lowercased()
    }

    /// Splits on separators and on camel-case humps.
    ///
    /// The hump rule handles the acronym case as well: `HTTPClient` breaks
    /// before the `C`, because an uppercase run ends where the next word's
    /// lowercase begins — giving "http client" rather than "h t t p client".
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)

        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }

        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // Break before an uppercase that starts a new word: either the
                // character before it was lowercase ("authProvider"), or the one
                // after it is ("HTTPClient").
                if previous.isLowercase || previous.isNumber || next?.isLowercase == true {
                    flush()
                }
            }
            current.append(character)
        }
        flush()
        return words
    }

    /// The ways a filename gets said out loud.
    ///
    /// Three of them, because all three happen: the whole thing, the stem on
    /// its own — far and away the most common — and the stem with the extension
    /// spelled the way people actually say it.
    static func filenameForms(_ name: String) -> [String] {
        guard let dot = name.lastIndex(of: ".") else { return [phrase(name)] }
        let stem = String(name[name.startIndex..<dot])
        let ext = String(name[name.index(after: dot)...])
        return [
            phrase(name),
            phrase(stem),
            "\(phrase(stem)) dot \(phrase(ext))",
        ]
    }

    /// A filename for somewhere with no trigger word in front of it.
    ///
    /// The bare stem is the difference. With "at" ahead of it, "auth provider"
    /// unambiguously means the file. Without one — a terminal, where there is
    /// nothing to link — "auth provider" is just two words, and rewriting them
    /// into a filename would corrupt an ordinary sentence. So the extension has
    /// to be said.
    static func untriggeredFilenameForms(_ name: String) -> [String] {
        guard let dot = name.lastIndex(of: ".") else { return [phrase(name)] }
        let stem = String(name[name.startIndex..<dot])
        let ext = String(name[name.index(after: dot)...])
        return [phrase(name), "\(phrase(stem)) dot \(phrase(ext))"]
    }

    /// "feature/roster-reader" → "feature slash roster reader".
    static func pathPhrase(_ path: String) -> String {
        path.split(separator: "/")
            .map { phrase(String($0)) }
            .joined(separator: " slash ")
    }

    /// "PAR-142" → "par 142". The transcriber writes the number as digits about
    /// as often as not, and the digit form is the one worth matching — a
    /// spelled-out "one forty two" is a different problem.
    static func issueKey(_ key: String) -> String {
        phrase(key)
    }
}
