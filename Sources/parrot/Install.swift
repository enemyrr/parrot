import ArgumentParser
import Foundation

/// Kept for the install script and any muscle memory built on the old flags.
/// The real implementations live in `Start` / `Stop`; this just forwards.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Deprecated — use `parrot start` / `parrot stop`."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            FileHandle.standardError.write(Data(
                "note: `parrot install --uninstall` is now `parrot stop`\n".utf8
            ))
            var stop = Stop()
            stop.keepAtLogin = false
            try stop.run()
        } else {
            FileHandle.standardError.write(Data(
                "note: `parrot install --launch-at-login` is now `parrot start`\n".utf8
            ))
            var start = Start()
            start.binary = nil
            try start.run()
        }
    }
}
