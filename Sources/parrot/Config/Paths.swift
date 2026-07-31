import Foundation

/// Where parrot keeps its files.
///
/// Data lives under `~/.local/share` — XDG-style, so it doesn't end up in the
/// user's Library and is easy to point elsewhere in tests. Settings themselves
/// are not here: they are in macOS preferences, and `configDirectory` survives
/// only because that is where the retired `config.toml` sat and the migrator
/// still has to go and find it.
enum ParrotPaths {
    static var configDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("parrot")
    }

    static var dataDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        return base.appendingPathComponent("parrot")
    }

    static var historyFile: URL {
        dataDirectory.appendingPathComponent("history.jsonl")
    }

    /// Usage counters. Separate from history because history is pruned and
    /// clearable, so lifetime totals can't be derived from it.
    static var statsFile: URL {
        dataDirectory.appendingPathComponent("stats.jsonl")
    }

    /// Daemon logs. `~/Library/Logs` rather than `/tmp` so they survive a
    /// reboot and show up in Console.app.
    static var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/parrot", isDirectory: true)
    }

    static var stdoutLog: URL { logDirectory.appendingPathComponent("parrot.out.log") }
    static var stderrLog: URL { logDirectory.appendingPathComponent("parrot.err.log") }

    private static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }
}
