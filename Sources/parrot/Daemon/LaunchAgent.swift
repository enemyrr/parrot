import Foundation

/// launchd plumbing for the background daemon.
///
/// We deliberately do NOT use `SMAppService.mainApp` — that requires a full
/// `.app` bundle. parrot ships as a single binary, so a plain LaunchAgent
/// plist is the simpler, more honest mechanism.
enum LaunchAgent {
    static let label = "com.digimata.parrot"

    /// The canonical install path. `start` prefers this, but `--binary` can
    /// point the agent anywhere — handy for running a dev build without sudo.
    static let installedBinary = "/usr/local/bin/parrot"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - State

    struct State {
        let installed: Bool
        /// Loaded into launchd — may still be between restarts.
        let loaded: Bool
        let pid: Int32?
        let lastExitStatus: Int32?
        /// Binary the plist actually points at, which is not necessarily the
        /// one on `$PATH`.
        let binary: String?

        var isRunning: Bool { pid != nil }
    }

    static func state() -> State {
        let binary = plistBinary()
        guard let line = launchctlListLine() else {
            return State(
                installed: isInstalled, loaded: false, pid: nil,
                lastExitStatus: nil, binary: binary
            )
        }
        // `launchctl list` emits: <pid|-> \t <last exit status> \t <label>
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        let pid = fields.first.flatMap { Int32($0) }
        let status = fields.count > 1 ? Int32(fields[1]) : nil
        return State(
            installed: isInstalled, loaded: true, pid: pid,
            lastExitStatus: status, binary: binary
        )
    }

    /// The binary path recorded in the installed plist.
    static func plistBinary() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    // MARK: - Lifecycle

    static func install(binary: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            // Restart on crash, but respect a clean exit (^C, quit from the
            // menu bar) instead of immediately relaunching.
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": ParrotPaths.stdoutLog.path,
            "StandardErrorPath": ParrotPaths.stderrLog.path,
        ]

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: ParrotPaths.logDirectory,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    static func uninstall() throws {
        guard isInstalled else { return }
        _ = bootout()
        try FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func bootstrap() -> Result {
        launchctl(["bootstrap", domain, plistURL.path])
    }

    @discardableResult
    static func bootout() -> Result {
        launchctl(["bootout", domain, plistURL.path])
    }

    /// `-k` kills the running instance first, so this picks up a rebuilt
    /// binary at the same path.
    @discardableResult
    static func kickstart() -> Result {
        launchctl(["kickstart", "-k", "\(domain)/\(label)"])
    }

    /// Resolve which binary the agent should run: an explicit override, else
    /// the canonical install path, else whichever binary is running this
    /// command (so a dev build can register itself).
    static func resolveBinary(override: String?) throws -> String {
        let fm = FileManager.default
        if let override {
            let path = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .standardizedFileURL.path
            guard fm.isExecutableFile(atPath: path) else {
                throw DaemonError.notExecutable(path)
            }
            return path
        }
        if fm.isExecutableFile(atPath: installedBinary) {
            return installedBinary
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if argv0.hasPrefix("/"), fm.isExecutableFile(atPath: argv0) {
            return argv0
        }
        throw DaemonError.binaryNotFound
    }

    // MARK: - launchctl

    struct Result {
        let status: Int32
        let stderr: String
        var stdout: String = ""
        var ok: Bool { status == 0 }
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func launchctlListLine() -> String? {
        launchctl(["list"]).stdout
            .split(separator: "\n")
            .first { $0.hasSuffix("\t\(label)") }
            .map(String.init)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return Result(status: -1, stderr: "\(error)", stdout: "")
        }
        // Read before waiting so a large `launchctl list` can't fill the pipe
        // buffer and deadlock the child.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(
            status: task.terminationStatus,
            stderr: String(data: errData, encoding: .utf8) ?? "",
            stdout: String(data: outData, encoding: .utf8) ?? ""
        )
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case binaryNotFound
    case notExecutable(String)

    var description: String {
        switch self {
        case .binaryNotFound:
            return """
                couldn't locate a parrot binary to run.
                install one to \(LaunchAgent.installedBinary), or pass --binary <path>.
                """
        case .notExecutable(let path):
            return "not an executable file: \(path)"
        }
    }
}
