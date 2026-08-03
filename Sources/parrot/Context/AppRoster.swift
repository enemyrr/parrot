import Foundation

/// A name that was on screen and can be spoken about.
///
/// The unit the whole integration feature is built on, and deliberately a
/// narrow one: a roster is *names*, never content. A channel in the sidebar, a
/// person who posted, a file in the tab bar, an identifier in the code. That
/// restriction is what lets dictation read a window at all — see `AppRoster`.
struct AppEntity: Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// A channel. Tagged with `#`.
        case channel
        /// Someone who can be mentioned. Tagged with `@`.
        case person
        /// A file. Tagged with `@`, which is the sigil an editor's chat box uses
        /// for its own file picker.
        case file
        /// An identifier out of the code on screen. Never tagged — it is
        /// spelling help, not a reference, so it carries no sigil.
        case symbol

        /// What goes in front of the literal when it is tagged.
        var sigil: String {
            switch self {
            case .channel: return "#"
            case .person, .file: return "@"
            case .symbol: return ""
            }
        }

        /// What you say to reach for one. Nil for the kinds that aren't tagged.
        ///
        /// These are the words Willow taught people, and they are the right
        /// ones: they're what the sigil is *called*, so nobody has to learn a
        /// parrot-specific incantation.
        var triggers: [String]? {
            switch self {
            case .channel:
                // The transcriber splits it about half the time.
                return ["hashtag", "hash tag"]
            case .person, .file:
                return ["at"]
            case .symbol:
                return nil
            }
        }

        var pluralName: String {
            switch self {
            case .channel: return "channels"
            case .person: return "people"
            case .file: return "files"
            case .symbol: return "symbols"
            }
        }
    }

    let kind: Kind
    /// What lands in the field, with the sigil already on it.
    let literal: String
    /// Lowercased word sequences that mean it. More than one because a file is
    /// said as "auth provider" about as often as "auth provider dot tsx", and
    /// missing either one is a tag that silently doesn't fire.
    let spokenForms: [String]

    init(kind: Kind, literal: String, spokenForms: [String]) {
        self.kind = kind
        self.literal = literal
        // Deduplicated and ordered longest-first so the tagger's alternation
        // prefers the most specific form it can match.
        var seen = Set<String>()
        self.spokenForms = spokenForms
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }

    /// The bare name, sigil stripped — what the transcriber and the cleaner
    /// want. A hint list is not a place for punctuation.
    var bareLiteral: String {
        // Obsidian's literal is a wiki link rather than a sigil and a name, and
        // "[[Architecture notes]]" is not a hint anyone can pronounce.
        if literal.hasPrefix("[["), literal.hasSuffix("]]"), literal.count > 4 {
            return String(literal.dropFirst(2).dropLast(2))
        }
        let sigil = kind.sigil
        guard !sigil.isEmpty, literal.hasPrefix(sigil) else { return literal }
        return String(literal.dropFirst(sigil.count))
    }
}

/// What one look at one app's window turned up.
///
/// Carries its own diagnostics because the interesting failure is not an error
/// — it is an empty result, and "the walk found nothing" and "the walk never
/// ran" have to be told apart by anything deciding whether the integration
/// still works.
struct AppRoster: Equatable {
    /// Which integration produced it. Nil only for `.none`.
    let integrationID: String?
    let app: String
    let bundleID: String?
    let entities: [AppEntity]
    /// Nodes the walk reached, for the inspector.
    let nodes: Int
    let elapsed: TimeInterval
    /// Set when the walk hit a limit rather than finishing. A truncated roster
    /// is still used — it is a list of names, and a short list of real names
    /// beats no list.
    let truncated: Bool
    /// Why there is nothing here, when there is nothing here.
    let unavailable: IntegrationUnavailable?
    /// Something that limited the read without failing it — and that the user
    /// can do something about. The one that matters in practice: a VS Code fork
    /// keeps its editor buffer off the accessibility tree until screen-reader
    /// mode is on, so files are found and identifiers are not. Without this the
    /// user sees a working integration that quietly does half its job.
    var note: String? = nil

    static let none = AppRoster(
        integrationID: nil, app: "", bundleID: nil, entities: [],
        nodes: 0, elapsed: 0, truncated: false, unavailable: .noIntegration
    )

    static func failed(
        _ reason: IntegrationUnavailable,
        integrationID: String?,
        app: String,
        bundleID: String?,
        nodes: Int = 0,
        elapsed: TimeInterval = 0
    ) -> AppRoster {
        AppRoster(
            integrationID: integrationID, app: app, bundleID: bundleID, entities: [],
            nodes: nodes, elapsed: elapsed, truncated: false, unavailable: reason
        )
    }

    /// Below this, the roster is thrown away and the dictation runs as though
    /// there were no integration at all.
    ///
    /// One name is not a roster — it is an app that exposed a single stray
    /// label, and tagging off the back of it is worse than not tagging. Two is
    /// the smallest number that says the walk actually found the thing it was
    /// looking for.
    static let minimumEntities = 2

    var isUsable: Bool {
        unavailable == nil && entities.count >= Self.minimumEntities
    }

    func entities(of kind: AppEntity.Kind) -> [AppEntity] {
        entities.filter { $0.kind == kind }
    }

    /// The names worth handing the transcriber and the cleaner.
    ///
    /// Bare, sigil-free, and capped: a vocabulary hint list is a prompt the user
    /// pays for on every dictation, and the tail of a frequency-ranked list of
    /// identifiers earns nothing.
    func vocabulary(limit: Int = 60) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entity in entities {
            let bare = entity.bareLiteral
            // Single short tokens are as likely to be a false positive as a
            // real term, and a wrong hint actively steers the decoder wrong.
            guard bare.count >= 3, seen.insert(bare.lowercased()).inserted else { continue }
            out.append(bare)
            if out.count >= limit { break }
        }
        return out
    }

    /// One line for the log: "Slack · 14 channels, 6 people · 240ms".
    var summary: String {
        if let unavailable {
            return "\(app.isEmpty ? "no app" : app) · \(unavailable.logDescription)"
        }
        let counts = AppEntity.Kind.allCases.compactMap { kind -> String? in
            let count = entities(of: kind).count
            return count > 0 ? "\(count) \(kind.pluralName)" : nil
        }
        let body = counts.isEmpty ? "nothing" : counts.joined(separator: ", ")
        return String(format: "%@ · %@ · %.0fms%@",
                      app, body, elapsed * 1000, truncated ? " (truncated)" : "")
    }
}

/// Why an integration isn't doing anything.
///
/// The whole point of naming these separately is the settings window: an app
/// that isn't running and an app that is running but exposes nothing are the
/// same blank row to a user, and only one of them is worth doing something
/// about.
enum IntegrationUnavailable: String, Equatable, Codable {
    /// No integration claims this app.
    case noIntegration
    /// The app isn't on this Mac. Display-only — an app that isn't installed
    /// can't be in front, so nothing on the dictation path ever sees this.
    case notInstalled
    /// The user switched this one off, or switched the feature off.
    case off
    /// Accessibility isn't granted, so no app can be read.
    case noAccessibility
    /// A password manager, or an app on the never-read list.
    case excluded
    /// The app is in front but published no window to walk.
    case noWindow
    /// The walk ran and came back with nothing usable. The interesting one:
    /// this is what an app that changed its UI out from under us looks like.
    case nothingFound
    /// Enough consecutive `nothingFound` results that parrot stopped asking.
    /// Sticky until the app restarts or the user rechecks — see
    /// `IntegrationMonitor`.
    case gaveUp

    var logDescription: String {
        switch self {
        case .noIntegration: return "no integration"
        case .notInstalled: return "not installed"
        case .off: return "off"
        case .noAccessibility: return "accessibility not granted"
        case .excluded: return "excluded"
        case .noWindow: return "no window"
        case .nothingFound: return "nothing found"
        case .gaveUp: return "gave up after repeated empty reads"
        }
    }

    /// What the settings row says. Short, because it sits in a badge.
    var badge: String {
        switch self {
        case .noIntegration: return "Unsupported"
        case .notInstalled: return "Not installed"
        case .off: return "Off"
        case .noAccessibility: return "Needs permission"
        case .excluded: return "Excluded"
        case .noWindow, .nothingFound, .gaveUp: return "Unavailable"
        }
    }

    /// The sentence under the row. Says what to do where there is something to
    /// do, and says so plainly where there isn't.
    var explanation: String {
        switch self {
        case .noIntegration:
            return "No integration for this app yet."
        case .notInstalled:
            return "Not installed on this Mac."
        case .off:
            return "Switched off."
        case .noAccessibility:
            return "parrot needs Accessibility to read any app. Grant it in Permissions."
        case .excluded:
            return "This app is on the never-read list."
        case .noWindow:
            return "The app was in front but published no window to read."
        case .nothingFound:
            return "Nothing readable last time. The app may have been on a screen "
                + "with no names on it."
        case .gaveUp:
            return "Came back empty several times in a row, so parrot stopped asking. "
                + "It'll try again when the app restarts, or check now."
        }
    }
}
