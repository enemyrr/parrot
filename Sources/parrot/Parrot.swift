import AppKit
import ArgumentParser
import Foundation

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold fn to talk, double-tap for hands-free.",
        subcommands: [
            Run.self, Start.self, Stop.self, Restart.self, Status.self, Logs.self,
            SettingsCommand.self, Setup.self, Doctor.self, Models.self,
            History.self, Stats.self, Key.self, Cleanup.self, Install.self,
            OverlayPreview.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    // Accepted and ignored. Installed LaunchAgent plists written by older
    // builds pass this, and rejecting it would leave the daemon unable to start
    // after an upgrade until someone re-ran `parrot start`. Startup no longer
    // blocks on checks at all — the settings window reports them instead.
    @Flag(name: .long, help: .hidden)
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay for this run.")
    var noOverlay: Bool = false

    func run() throws {
        // Before anything reads the store: an existing config.toml is folded in
        // once, then retired.
        LegacyConfigMigration.runIfNeeded()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = MainActor.assumeIsolated { DictationController() }
        MainActor.assumeIsolated {
            controller.debugHotkey = debugHotkey
            controller.dumpWav = dumpWav
            controller.overlaySuppressed = noOverlay
            controller.start()
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.stop() }
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data("parrot running · ^C to quit\n".utf8))
        app.run()
    }
}

/// Opens the settings window on its own, with no daemon behind it.
///
/// Every pane still reads and writes settings; the ones that need a live engine
/// — the model's load state, the microphone preview — say so rather than
/// pretending. Runs as a regular app so ⌘Q and the dock behave normally, unlike
/// the accessory-mode daemon.
struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Open the settings window."
    )

    @Option(name: .long, help: "Pane to open on: \(SettingsCommand.paneList).")
    var pane: String?

    static var paneList: String {
        SettingsPane.allCases.map(\.rawValue).joined(separator: " | ")
    }

    func run() throws {
        LegacyConfigMigration.runIfNeeded()

        let requested: SettingsPane
        if let pane {
            guard let match = SettingsPane(rawValue: pane.lowercased()) else {
                throw ValidationError("Unknown pane '\(pane)'. Use one of: \(Self.paneList).")
            }
            requested = match
        } else {
            requested = .general
        }

        // The daemon owns the real window, with a live engine behind it, and
        // there is no channel to ask it to come forward — so this opens a
        // second, inert copy. Say so: changes made here are written to the same
        // preferences, but the running daemon read those at launch and won't
        // see them until it restarts.
        if LaunchAgent.state().isRunning {
            print("parrot is already running. This window edits the same settings, but the")
            print("running daemon won't pick them up until `parrot restart`.")
            print("Its own settings window is under the menu bar icon.")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MainActor.assumeIsolated { StandaloneSettingsDelegate(pane: requested) }
        app.delegate = delegate
        app.run()
    }
}

/// Keeps the standalone window alive and quits with it.
@MainActor
final class StandaloneSettingsDelegate: NSObject, NSApplicationDelegate {
    private let pane: SettingsPane

    init(pane: SettingsPane) {
        self.pane = pane
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.shared.show(pane: pane)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// First-run setup, which now lives in the settings window. Kept as a command
/// because the install script and a lot of muscle memory point at it.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the permissions checklist."
    )

    func run() throws {
        var settings = SettingsCommand()
        settings.pane = SettingsPane.permissions.rawValue
        try settings.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, Fn key, model and cleanup."
    )

    func run() throws {
        let checks = DoctorReport.run(settings: SettingsStore.current())
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            print("")
            // Only point at the Permissions pane when that's where the failure
            // actually is — an unknown language code can't be fixed there, and
            // sending someone to a pane with no control for their problem is
            // worse than not naming a pane at all.
            let failed = checks.filter { if case .fail = $0.status { return true } else { return false } }
            let permissionsOnly = failed.allSatisfy { DoctorReport.requiredKinds.contains($0.kind) }
            print(permissionsOnly
                ? "Fix these in the settings window: parrot settings --pane permissions"
                : "Fix these in the settings window: parrot settings")
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            let active = SettingsStore.current().resolvedModel.id
            for m in ModelRegistry.shared {
                let marker = m.id == active ? "●" : (m.recommended ? "★" : " ")
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = m.isLocal ? String(format: "%5d MB", m.sizeMB) : "   cloud"
                let state: String
                if m.isLocal {
                    state = m.isDownloaded ? "downloaded" : "not downloaded"
                } else if let account = m.engine.keychainAccount {
                    state = Keychain.apiKey(for: account) != nil
                        ? "\(account.displayName) key found"
                        : "needs an \(account.displayName) key"
                } else {
                    state = "ready"
                }
                print("\(marker) \(id) \(size)  \(langs)  \(m.displayName)  · \(state)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            guard m.isLocal else {
                print("\(m.id) runs in the cloud — there is nothing to download.")
                print("Give it a key instead: parrot key set openai")
                throw ExitCode(1)
            }
            let transcriber = ParakeetTranscriber(model: m)

            let semaphore = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await transcriber.warmUp() } catch { capturedError = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let capturedError { throw capturedError }
        }
    }
}

/// A pure container: every option lives on a subcommand. An option declared
/// here as well would shadow the identically-named one on `search`, and the
/// subcommand would silently keep its default.
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Browse past transcriptions.",
        subcommands: [List.self, Search.self, Clear.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the most recent transcriptions."
        )

        @Option(name: .shortAndLong, help: "How many entries to show.")
        var number: Int = 20

        func run() throws {
            let store = TranscriptStore(settings: SettingsStore.current().history)
            let entries = store.recent(number)
            guard !entries.isEmpty else {
                print("no history yet — \(store.path)")
                return
            }
            for entry in entries.reversed() {
                print(History.format(entry))
            }
        }
    }

    static func format(_ entry: TranscriptEntry) -> String {
        let stamp = DateFormatter.historyStamp.string(from: entry.at)
        let marks = [entry.latched ? "🔒" : nil, entry.cleaned ? "✨" : nil]
            .compactMap { $0 }
            .joined()
        let suffix = marks.isEmpty ? "" : " \(marks)"
        return "\(stamp)\(suffix)  \(entry.text)"
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Case-insensitive substring search over past transcripts."
        )

        @Argument(help: "Text to look for.") var query: String

        @Option(name: .shortAndLong, help: "Maximum matches to show.")
        var number: Int = 20

        func run() throws {
            let store = TranscriptStore(settings: SettingsStore.current().history)
            let matches = store.search(query, limit: number)
            guard !matches.isEmpty else {
                print("no matches for \"\(query)\"")
                return
            }
            for entry in matches.reversed() {
                print(History.format(entry))
            }
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete all history.")

        @Flag(name: .long, help: "Skip the confirmation prompt.")
        var yes: Bool = false

        func run() throws {
            let store = TranscriptStore(settings: SettingsStore.current().history)
            if !yes {
                print("Delete every transcript in \(store.path)? [y/N] ", terminator: "")
                let answer = readLine()?.lowercased() ?? ""
                guard answer == "y" || answer == "yes" else {
                    print("cancelled")
                    return
                }
            }
            try store.clear()
            print("history cleared")
        }
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "How much you've dictated.",
        subcommands: [Show.self, Reset.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show usage totals.")

        @Option(name: .shortAndLong, help: "Days to include in the sparkline.")
        var days: Int = 30

        func run() throws {
            let settings = SettingsStore.current()
            let store = StatsStore(settings: settings.stats)
            let summary = store.summary(typingWpm: settings.stats.typingWpm)

            guard summary.sessions > 0 else {
                print(settings.stats.enabled
                    ? "nothing dictated yet — \(store.path)"
                    : "usage counting is off — turn it on in `parrot settings`")
                return
            }

            let dayLabel = summary.daysUsed == 1 ? "day" : "days"
            print("")
            print("  \(summary.words.formatted()) words  ·  \(summary.daysUsed) \(dayLabel) used")
            print("  \(Stats.duration(summary.secondsSaved)) saved"
                + "  ·  vs typing at \(Int(settings.stats.typingWpm)) wpm")
            print("  \(Int(summary.averageWpm.rounded())) wpm speaking"
                + "  ·  \(summary.sessions.formatted()) recordings"
                + "  ·  \(Int((summary.latchedShare * 100).rounded()))% hands-free")

            let points = store.daily(lastDays: days)
            if points.contains(where: { $0.words > 0 }) {
                print("")
                print("  last \(points.count) days")
                print("  \(Stats.sparkline(points.map(\.words)))")
            }

            if !summary.models.isEmpty {
                print("")
                let width = summary.models.map(\.model.count).max() ?? 0
                for model in summary.models {
                    let name = model.model.padding(toLength: width, withPad: " ", startingAt: 0)
                    let latency = model.averageProcessSeconds
                        .map { String(format: " · %.2fs avg", $0) } ?? ""
                    print("  \(name)  \(model.words.formatted()) words\(latency)")
                }
            }
            print("")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete all usage stats.")

        @Flag(name: .long, help: "Skip the confirmation prompt.")
        var yes: Bool = false

        func run() throws {
            let store = StatsStore(settings: SettingsStore.current().stats)
            if !yes {
                print("Delete every usage total in \(store.path)? [y/N] ", terminator: "")
                let answer = readLine()?.lowercased() ?? ""
                guard answer == "y" || answer == "yes" else {
                    print("cancelled")
                    return
                }
            }
            try store.reset()
            print("stats cleared")
        }
    }

    /// Rounded to whatever unit reads cleanly — "saved 2847 seconds" is a
    /// number, "47 min" is an answer.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func sparkline(_ values: [Int]) -> String {
        let blocks = Array("▁▂▃▄▅▆▇█")
        guard let peak = values.max(), peak > 0 else { return "" }
        return String(values.map { value -> Character in
            guard value > 0 else { return "·" }
            // Scaled so the busiest day is full height and any day with words
            // in it clears the floor — a one-word day shouldn't read as zero.
            let level = Int((Double(value) / Double(peak) * Double(blocks.count - 1)).rounded())
            return blocks[min(blocks.count - 1, max(0, level))]
        })
    }
}

extension Keychain.Account: ExpressibleByArgument {}

/// Keys are their own command now that one can serve two features — the OpenAI
/// key belongs to a transcription model as much as to cleanup, and
/// `parrot cleanup set-key openai` said otherwise.
struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Manage provider API keys in the Keychain.",
        subcommands: [Set.self, Clear.self, List.self]
    )

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a provider API key in the Keychain."
        )

        @Argument(help: "Provider the key belongs to (anthropic | openai).")
        var provider: Keychain.Account = .openai

        func run() throws {
            print("\(provider.displayName) API key: ", terminator: "")
            // Echoing is fine here — the alternative is fighting termios for a
            // one-shot setup command the user runs alone at a prompt.
            guard let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty
            else {
                print("no key entered")
                throw ExitCode(1)
            }
            try Keychain.write(key, for: provider)
            print("saved to the Keychain")
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a stored provider API key."
        )

        @Argument(help: "Provider whose key to remove (anthropic | openai).")
        var provider: Keychain.Account = .openai

        func run() throws {
            try Keychain.delete(provider)
            print("key removed")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show which providers have a key, without printing any."
        )

        func run() throws {
            for account in Keychain.Account.allCases {
                let source: String
                if Keychain.read(account)?.isEmpty == false {
                    source = "keychain"
                } else if ProcessInfo.processInfo.environment[account.envVar]?.isEmpty == false {
                    source = account.envVar
                } else {
                    source = "—"
                }
                let name = account.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("\(name) \(source)")
            }
        }
    }
}

struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the optional transcript cleanup pass.",
        subcommands: [SetKey.self, ClearKey.self]
    )

    /// Kept as an alias of `parrot key set`. Someone has this in a setup script
    /// or a shell alias, and breaking it to rename a command isn't a trade
    /// worth making.
    struct SetKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-key",
            abstract: "Deprecated alias for `parrot key set`."
        )

        @Argument(help: "Provider the key belongs to (anthropic | openai).")
        var provider: Keychain.Account = .anthropic

        func run() throws {
            var command = Key.Set()
            command.provider = provider
            try command.run()
        }
    }

    struct ClearKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-key",
            abstract: "Deprecated alias for `parrot key clear`."
        )

        @Argument(help: "Provider whose key to remove (anthropic | openai).")
        var provider: Keychain.Account = .anthropic

        func run() throws {
            var command = Key.Clear()
            command.provider = provider
            try command.run()
        }
    }
}

extension DateFormatter {
    static let historyStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
