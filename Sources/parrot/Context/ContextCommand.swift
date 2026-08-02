import AppKit
import ArgumentParser
import Foundation

/// `parrot context` — prints exactly what squawk would read off the screen.
///
/// The one honest answer to "why did it write that". Screen capture is the part
/// of squawk nobody can see, and a feature that reads your windows and won't
/// show you what it read is asking for trust it hasn't earned. It is also how
/// coverage in a new app gets checked: run it, look, adjust.
struct ContextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Show what squawk would read from the app in front."
    )

    @Option(name: .long, help: "Seconds to wait before reading, to go click into another app.")
    var delay: Double = 3

    @Option(name: .long, help: "Character budget for the window text.")
    var limit: Int = ScreenReader.Limits.default.maxCharacters

    @Flag(name: .long, help: "Print the raw text instead of a summary.")
    var full: Bool = false

    @Flag(name: .long, help: "Don't ask Chromium apps to build an accessibility tree.")
    var noElectron: Bool = false

    @Flag(name: .long, help: "Dump the raw accessibility tree instead — for tuning the filter.")
    var tree: Bool = false

    @Option(name: .long, help: "Read this app by name instead of whatever is in front.")
    var app: String?

    @Flag(name: .long, help: "List the apps that can be read by name.")
    var list: Bool = false

    func run() throws {
        guard AXIsProcessTrusted() else {
            print("Accessibility isn't granted — nothing can be read.")
            print("Open `parrot settings` → Permissions, or System Settings →")
            print("Privacy & Security → Accessibility.")
            throw ExitCode(1)
        }

        var limits = ScreenReader.Limits.default
        limits.maxCharacters = limit
        limits.enhanceChromium = !noElectron

        if list {
            print(MainActor.assumeIsolated { AppTarget.running() }.joined(separator: "\n"))
            return
        }

        let target: AppTarget
        if let app {
            guard let named = MainActor.assumeIsolated({ AppTarget.named(app) }) else {
                print("No running app matches '\(app)'. Try --list.")
                throw ExitCode(1)
            }
            target = named
        } else {
            if delay > 0 {
                print("Reading the frontmost app in \(Int(delay))s — click into it now.")
                Thread.sleep(forTimeInterval: delay)
            }
            guard let front = MainActor.assumeIsolated({ AppTarget.frontmost() }) else {
                print("No frontmost app (or it's parrot itself).")
                throw ExitCode(1)
            }
            target = front
        }

        if tree {
            print(ScreenReader.dumpTree(target, limits: limits))
            return
        }

        let context = ScreenReader.capture(target, limits: limits)
        print(Self.report(context, full: full))
    }

    static func report(_ context: ScreenContext, full: Bool) -> String {
        var out: [String] = []
        out.append("app        \(context.app)\(context.bundleID.map { "  (\($0))" } ?? "")")
        out.append("window     \(context.windowTitle ?? "—")")
        out.append(String(format: "read in    %.0f ms%@",
                          context.elapsed * 1000, context.truncated ? "  (hit the budget)" : ""))
        out.append("captured   \(context.characterCount) chars")
        out.append("filtered   \(context.filtered)")
        if full {
            let roles = context.roleHistogram.sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            out.append("roles      \(roles)")
        }
        out.append("")

        func section(_ name: String, _ body: String?) {
            guard let body else {
                out.append("── \(name) — none")
                out.append("")
                return
            }
            out.append("── \(name) (\(body.count) chars)")
            out.append(full ? body : String(body.prefix(600)))
            if !full, body.count > 600 { out.append("… (--full for the rest)") }
            out.append("")
        }

        section("selection", context.selection)
        section("focused field", context.focusedText)
        section("window text", context.windowText)

        if let skipped = context.skipped {
            out.append(Self.explain(skipped))
        } else if !context.hasContent {
            out.append("Nothing readable. Try --tree to see what the app actually exposes.")
        }
        return out.joined(separator: "\n")
    }

    private static func explain(_ reason: ScreenContext.SkipReason) -> String {
        switch reason {
        case .excludedApp:
            return "This app is never read — password managers and the login window are "
                + "excluded outright, whatever the settings say."
        case .noAccessibility:
            return "Accessibility isn't granted, so nothing can be read."
        case .noWindow:
            return "The app has no window parrot can find. Some apps only publish one "
                + "once a document is open."
        }
    }
}
