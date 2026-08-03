import AppKit
import ArgumentParser
import Foundation

/// `parrot roster` — prints the names an integration would find in an app.
///
/// The counterpart to `parrot context`, and it exists for a sharper reason.
/// Every classifier in `AppIntegration` is a guess about how one app lays its
/// window out, and an app is free to change that in any release. This is how a
/// guess gets checked, and how the next one gets written: run it, look at what
/// came back, adjust the rule. `--nodes` prints what the walk actually saw,
/// which is where you go when the answer is "nothing".
struct RosterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roster",
        abstract: "Show the names an integration would read from an app."
    )

    @Option(name: .long, help: "Seconds to wait before reading, to go click into another app.")
    var delay: Double = 3

    @Option(name: .long, help: "Read this app by name instead of whatever is in front.")
    var app: String?

    @Flag(name: .long, help: "Print the labels the walk saw, with their positions.")
    var nodes: Bool = false

    @Flag(name: .long, help: "List every app with an integration.")
    var list: Bool = false

    @Flag(name: .long, help: "Don't ask Chromium apps to build an accessibility tree.")
    var noElectron: Bool = false

    func run() throws {
        if list {
            for integration in AppIntegrations.all {
                print("\(integration.name)  (\(integration.id))")
                print("  \(integration.blurb)")
                print("  finds: \(integration.kinds.map(\.pluralName).joined(separator: ", "))")
                print("  \(integration.bundleIDs.joined(separator: ", "))\n")
            }
            return
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility isn't granted — nothing can be read.")
            print("Open `parrot settings` → Permissions, or System Settings →")
            print("Privacy & Security → Accessibility.")
            throw ExitCode(1)
        }

        let target: AppTarget
        if let app {
            guard let named = MainActor.assumeIsolated({ AppTarget.named(app) }) else {
                print("No running app matches '\(app)'. Try `parrot context --list`.")
                throw ExitCode(1)
            }
            target = named
        } else {
            if delay > 0 {
                print("Reading the app in front in \(Int(delay))s…")
                Thread.sleep(forTimeInterval: delay)
            }
            guard let front = MainActor.assumeIsolated({ AppTarget.frontmost() }) else {
                print("No app in front to read.")
                throw ExitCode(1)
            }
            target = front
        }

        guard let integration = AppIntegrations.integration(for: target.bundleID) else {
            print("\(target.name) (\(target.bundleID ?? "no bundle id"))")
            print("No integration claims this app. `parrot roster --list` shows the ones there are.")
            throw ExitCode(1)
        }

        var limits = RosterReader.Limits.default
        limits.enhanceChromium = !noElectron
        // The CLI has to be able to ask twice in a row; the daemon's
        // once-per-window-of-time gate would make the second run read a tree
        // nobody asked to be built.
        ScreenReader.forgetChromiumState(pid: target.pid)

        let (roster, scan) = RosterReader.readKeepingScan(
            target, integration: integration, limits: limits
        )
        print("\(integration.name) · \(roster.summary)")

        if let unavailable = roster.unavailable {
            print(unavailable.explanation)
        }
        if let note = roster.note {
            print("note: \(note)")
        }

        for kind in AppEntity.Kind.allCases {
            let found = roster.entities(of: kind)
            guard !found.isEmpty else { continue }
            print("\n── \(kind.pluralName) (\(found.count))")
            for entity in found {
                print("  \(entity.literal)   ← \(entity.spokenForms.joined(separator: " / "))")
            }
        }

        if nodes {
            // The raw material, for when the answer above is "nothing found"
            // and the question is which rule threw it away. The same walk the
            // roster came out of, so the two explain each other.
            printNodes(scan)
        }
    }

    private func printNodes(_ scan: RosterScan?) {
        guard let scan else {
            print("\n── labels\nNo window to walk.")
            return
        }
        print("\n── labels (\(scan.nodes.count))")
        for node in scan.nodes {
            let zone = scan.isInLeftRail(node) ? "rail" : "main"
            let x = node.frame.map { String(format: "%4.0f", $0.minX) } ?? "   ?"
            let y = node.frame.map { String(format: "%4.0f", $0.minY) } ?? "   ?"
            let text = node.text.replacingOccurrences(of: "\n", with: "⏎")
            print("  \(zone) \(x),\(y)  \(node.role.dropFirst(2))  \(text.prefix(90))")
        }
    }
}
