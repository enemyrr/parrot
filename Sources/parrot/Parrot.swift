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
            Setup.self, Doctor.self, Models.self, ConfigCommand.self,
            History.self, Cleanup.self, Install.self,
        ],
        defaultSubcommand: Run.self
    )
}

/// Load config or exit with a readable error. A malformed file is fatal on
/// purpose — silently falling back to defaults would hide a typo'd wordlist
/// until the user noticed their dictation behaving oddly.
func loadConfigOrExit() throws -> Config {
    do {
        return try Config.load()
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        throw ExitCode(1)
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Overrides the config file.")
    var model: String?

    @Option(name: .long, help: "Push-to-talk key (\(HotkeyMonitor.supportedHotkeys)).")
    var hotkey: String?

    func run() throws {
        let config = try loadConfigOrExit()

        let hotkeyName = hotkey ?? config.hotkey
        guard let hotkeyMask = HotkeyMonitor.mask(forHotkey: hotkeyName) else {
            FileHandle.standardError.write(Data("unknown hotkey: \(hotkeyName)\n".utf8))
            FileHandle.standardError.write(Data(
                "supported: \(HotkeyMonitor.supportedHotkeys)\n".utf8
            ))
            throw ExitCode(1)
        }

        if !skipDoctor {
            let checks = DoctorReport.run(config: config)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        // CLI flag beats config file beats the registry default.
        let requestedModel = model ?? config.model
        let chosenModel: TranscriptionModel
        if let id = requestedModel {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriber = ParakeetTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let wordlist = Wordlist(config: config.wordlist)
        let store = config.history.enabled ? TranscriptStore(config: config.history) : nil
        store?.prune()

        var cleaner: TextCleaner?
        if config.cleanup.enabled {
            switch makeCleaner(for: config.cleanup) {
            case .success(let c):
                cleaner = c
                FileHandle.standardError.write(Data("cleanup: \(c.name)\n".utf8))
            case .failure(let error):
                // Not fatal — dictation still works, just without cleanup.
                FileHandle.standardError.write(Data("cleanup disabled — \(error)\n".utf8))
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(mask: hotkeyMask, config: config.latch, debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, store: store)
        }

        let pipeline = DictationPipeline(
            transcriber: transcriber,
            wordlist: wordlist,
            cleaner: cleaner,
            cleanup: config.cleanup,
            store: store,
            modelID: chosenModel.id
        )
        var isLatched = false

        do {
            try monitor.start { event in
                switch event {
                case .begin:
                    do {
                        try capture.start()
                        isLatched = false
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setState(.recording)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }

                case .latched:
                    isLatched = true
                    FileHandle.standardError.write(Data("🔒 hands-free · tap fn to stop\n".utf8))
                    MainActor.assumeIsolated {
                        overlay?.show(.latched)
                        menuBar.setState(.latched)
                    }

                case .cancelled:
                    _ = capture.stop()
                    isLatched = false
                    FileHandle.standardError.write(Data("✗ cancelled\n".utf8))
                    MainActor.assumeIsolated {
                        overlay?.hide()
                        menuBar.setState(.idle)
                    }

                case .end:
                    let samples = capture.stop()
                    let wasLatched = isLatched
                    isLatched = false
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setState(.transcribing)
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/parrot-last.wav"
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    guard !samples.isEmpty else {
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setState(.idle)
                        }
                        return
                    }
                    Task {
                        let text = await pipeline.process(
                            samples: samples,
                            seconds: seconds,
                            latched: wasLatched
                        )
                        await MainActor.run {
                            if let text, !text.isEmpty {
                                TextInjector.inject(text)
                                menuBar.reloadRecents()
                            }
                            overlay?.hide()
                            menuBar.setState(.idle)
                        }
                    }
                }
            }
        } catch HotkeyMonitor.HotkeyError.accessibilityDenied {
            let remediation = DoctorReport.checkAccessibility().remediation ?? "run `parrot doctor`"
            FileHandle.standardError.write(Data("""
                accessibility not granted — the hotkey can't be registered.
                \(remediation)
                Then run `parrot restart` (or relaunch parrot).

                """.utf8))
            // Exit 0 deliberately. The LaunchAgent restarts on *failure*, and
            // retrying here would crash-loop, re-prompting for permission every
            // few seconds until someone grants it. This needs a human, so stop
            // cleanly and wait to be restarted.
            throw ExitCode(0)
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let latchHint = config.latch.enabled ? " · double-tap for hands-free" : ""
        FileHandle.standardError.write(Data(
            "listening on \(hotkeyName) hold\(latchHint) · model: \(chosenModel.id) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, Fn key, and config."
    )

    func run() throws {
        // Report a bad config as a failed check rather than exiting early —
        // doctor's whole job is to tell you what's wrong.
        let config = try? Config.load()
        let checks = DoctorReport.run(config: config)
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
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
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
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
            let t = ParakeetTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or create the config file.",
        subcommands: [Path.self, Init.self]
    )

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the config file path.")
        func run() throws {
            print(ParrotPaths.configFile.path)
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a commented default config file."
        )

        @Flag(name: .long, help: "Overwrite an existing config file.")
        var force: Bool = false

        func run() throws {
            let url = ParrotPaths.configFile
            if FileManager.default.fileExists(atPath: url.path), !force {
                print("config already exists at \(url.path)")
                print("pass --force to overwrite it.")
                throw ExitCode(1)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try DefaultConfigTemplate.contents.write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(url.path)")
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
            let config = try loadConfigOrExit()
            let store = TranscriptStore(config: config.history)
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
            let config = try loadConfigOrExit()
            let store = TranscriptStore(config: config.history)
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
            let config = try loadConfigOrExit()
            let store = TranscriptStore(config: config.history)
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

struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the optional transcript cleanup pass.",
        subcommands: [SetKey.self, ClearKey.self]
    )

    struct SetKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-key",
            abstract: "Store an Anthropic API key in the Keychain."
        )

        func run() throws {
            print("Anthropic API key: ", terminator: "")
            // Echoing is fine here — the alternative is fighting termios for a
            // one-shot setup command the user runs alone at a prompt.
            guard let key = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty
            else {
                print("no key entered")
                throw ExitCode(1)
            }
            try Keychain.write(key)
            print("saved to the Keychain")
        }
    }

    struct ClearKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-key",
            abstract: "Remove the stored Anthropic API key."
        )

        func run() throws {
            try Keychain.delete()
            print("key removed")
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
