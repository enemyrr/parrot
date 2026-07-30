import ArgumentParser
import Foundation

/// Reads the daemon's own stderr to report on it.
///
/// The CLI can't ask TCC about another process, and `AXIsProcessTrusted()` here
/// answers for *this* invocation (attributed to the terminal), not the daemon.
/// The daemon says what happened to it in its log; that's the honest source.
enum DaemonLog {
    enum Startup {
        case listening(String)
        case accessibilityDenied
        case failed(String)
        case unknown
    }

    static func size() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: ParrotPaths.stderrLog.path)[.size])
            .flatMap { $0 as? UInt64 } ?? 0
    }

    /// Read whatever the daemon has written since `offset`.
    static func text(since offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: ParrotPaths.stderrLog) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func classify(_ text: String) -> Startup {
        for line in text.split(separator: "\n").reversed() {
            if line.hasPrefix("listening on") { return .listening(String(line)) }
            if line.contains("accessibility not granted") { return .accessibilityDenied }
            if line.hasPrefix("warmup failed") || line.hasPrefix("failed to register") {
                return .failed(String(line))
            }
        }
        return .unknown
    }

    /// Poll until the daemon reports success or failure. Model load dominates
    /// startup, so allow generous time before giving up.
    static func waitForStartup(since offset: UInt64, timeout: TimeInterval = 25) -> Startup {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = classify(text(since: offset))
            if case .unknown = result {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            return result
        }
        return .unknown
    }

    static func report(_ startup: Startup) {
        switch startup {
        case .listening(let line):
            print("✓ \(line)")
        case .accessibilityDenied:
            print("")
            print("⚠️  the daemon stopped: accessibility isn't granted for the binary it runs.")
            print("   System Settings → Privacy & Security → Accessibility → enable parrot.")
            print("   Already listed? Toggle it off and back on — the grant is tied to the")
            print("   binary's contents, so a rebuilt parrot needs re-approving.")
            print("   Then: parrot restart")
        case .failed(let line):
            print("")
            print("⚠️  the daemon failed to start: \(line)")
            print("   full log: parrot logs")
        case .unknown:
            print("  (still starting — check `parrot logs`)")
        }
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run parrot in the background, now and at login."
    )

    @Option(
        name: .long,
        help: "Binary the daemon should run. Defaults to /usr/local/bin/parrot, or this binary."
    )
    var binary: String?

    func run() throws {
        let path = try LaunchAgent.resolveBinary(override: binary)
        let alreadyRunning = LaunchAgent.state().isRunning

        try LaunchAgent.install(binary: path)
        let offset = DaemonLog.size()

        // Boot out first so a changed plist or binary is picked up; ignore the
        // failure when nothing was loaded.
        LaunchAgent.bootout()
        let result = LaunchAgent.bootstrap()
        guard result.ok else {
            FileHandle.standardError.write(Data(
                "launchctl bootstrap failed (\(result.status)):\n\(result.stderr)\n".utf8
            ))
            throw ExitCode(1)
        }

        print(alreadyRunning ? "restarting parrot…" : "starting parrot…")
        print("  binary: \(path)")
        if path != LaunchAgent.installedBinary {
            print("  note:   non-standard binary — run `parrot restart` after each rebuild")
        }
        DaemonLog.report(DaemonLog.waitForStartup(since: offset))
        print("  logs:   parrot logs -f")
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the background daemon and unregister it from login."
    )

    @Flag(name: .long, help: "Stop now but keep it registered to start at login.")
    var keepAtLogin: Bool = false

    func run() throws {
        guard LaunchAgent.isInstalled else {
            print("parrot isn't registered as a background daemon")
            return
        }
        if keepAtLogin {
            let result = LaunchAgent.bootout()
            guard result.ok || result.stderr.contains("No such process") else {
                FileHandle.standardError.write(Data(
                    "launchctl bootout failed (\(result.status)):\n\(result.stderr)\n".utf8
                ))
                throw ExitCode(1)
            }
            print("✓ parrot stopped (still registered for login)")
            return
        }
        try LaunchAgent.uninstall()
        print("✓ parrot stopped and unregistered")
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart the daemon, picking up a rebuilt binary."
    )

    func run() throws {
        guard LaunchAgent.isInstalled else {
            FileHandle.standardError.write(Data(
                "parrot isn't running in the background — use `parrot start`\n".utf8
            ))
            throw ExitCode(1)
        }
        let offset = DaemonLog.size()
        let result = LaunchAgent.kickstart()
        guard result.ok else {
            FileHandle.standardError.write(Data(
                "launchctl kickstart failed (\(result.status)):\n\(result.stderr)\n".utf8
            ))
            throw ExitCode(1)
        }
        print("restarting parrot…")
        if let binary = LaunchAgent.plistBinary() {
            print("  binary: \(binary)")
        }
        DaemonLog.report(DaemonLog.waitForStartup(since: offset))
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether the background daemon is running."
    )

    func run() throws {
        let state = LaunchAgent.state()

        guard state.installed else {
            print("○ not running — parrot isn't registered as a background daemon")
            print("  start it with: parrot start")
            return
        }

        if let pid = state.pid {
            print("● running · pid \(pid)")
        } else {
            let exit = state.lastExitStatus.map { " · last exit \($0)" } ?? ""
            print("○ registered but not running\(exit)")
        }

        if let binary = state.binary {
            let marker = FileManager.default.isExecutableFile(atPath: binary) ? "" : "   ⚠️ missing"
            print("  binary:  \(binary)\(marker)")
        }
        print("  plist:   \(LaunchAgent.plistURL.path)")
        print("  logs:    \(ParrotPaths.stderrLog.path)")

        if let config = try? Config.load() {
            let model = config.model ?? ModelRegistry.recommended()?.id ?? "?"
            let cleanup = config.cleanup.enabled ? config.cleanup.provider.rawValue : "off"
            print("  model:   \(model)")
            print("  hotkey:  \(config.hotkey)\(config.latch.enabled ? " (double-tap to latch)" : "")")
            print("  cleanup: \(cleanup)")

            if config.history.enabled {
                let store = TranscriptStore(config: config.history)
                if let last = store.recent(1).first {
                    print("  last:    \(History.format(last))")
                }
            }
        }

        // What the daemon itself last reported, rather than a TCC probe that
        // would answer for this process instead of the daemon.
        let startup = DaemonLog.classify(DaemonLog.text(since: 0))
        switch startup {
        case .listening(let line) where state.isRunning:
            print("  state:   \(line)")
        case .listening:
            break
        default:
            DaemonLog.report(startup)
        }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the background daemon's log."
    )

    @Flag(name: .shortAndLong, help: "Follow the log as it grows.")
    var follow: Bool = false

    // `-n` to match tail; `--lines` reads better in scripts.
    @Option(name: [.customShort("n"), .long], help: "How many lines to show.")
    var lines: Int = 40

    func run() throws {
        let path = ParrotPaths.stderrLog.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("no log yet at \(path)")
            print("the daemon writes here once started — try: parrot start")
            return
        }
        var args = ["-n", String(lines)]
        if follow { args.append("-f") }
        args.append(path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 && !follow {
            throw ExitCode(task.terminationStatus)
        }
    }
}
