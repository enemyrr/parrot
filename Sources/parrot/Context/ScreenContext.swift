import AppKit
import ApplicationServices
import Foundation

/// What was on screen when you reached for the key.
///
/// Everything here is read through the Accessibility API — the same grant the
/// hotkey already needs, so squawk asks for nothing new. Nothing is read until
/// squawk is switched on, and nothing leaves the machine unless the configured
/// provider is a remote one.
struct ScreenContext: Equatable {
    /// "Mail". Always present — it is the one thing worth knowing even when the
    /// app exposes nothing else.
    let app: String
    let bundleID: String?
    let windowTitle: String?
    /// Highlighted text, if any. The strongest signal there is: it says what
    /// the user is pointing at without being asked.
    let selection: String?
    /// The focused field's own contents — a half-written reply, usually.
    let focusedText: String?
    /// Readable text from the focused window, filtered and in reading order.
    let windowText: String?
    /// Set when the window text hit the character budget or a walk limit.
    let truncated: Bool
    /// Why there is nothing here, when there is nothing here.
    let skipped: SkipReason?
    /// How long the walk took. Surfaced because it runs while you talk, and a
    /// slow app is the one thing that could make it not finish in time.
    let elapsed: TimeInterval
    /// What the filter threw away, for the inspector.
    var filtered: String = "nothing"
    /// Roles the walk reached, for tuning the tables.
    var roleHistogram: [String: Int] = [:]

    enum SkipReason: String, Equatable {
        /// A password manager or the login window. Never read, at all.
        case excludedApp
        case noAccessibility
        case noWindow
    }

    static func skipped(_ reason: SkipReason, app: String, bundleID: String? = nil) -> ScreenContext {
        ScreenContext(
            app: app, bundleID: bundleID, windowTitle: nil, selection: nil,
            focusedText: nil, windowText: nil, truncated: false,
            skipped: reason, elapsed: 0
        )
    }

    /// Whether there is anything here beyond the app's name.
    var hasContent: Bool {
        selection != nil || focusedText != nil || windowText != nil
    }

    var characterCount: Int {
        (selection?.count ?? 0) + (focusedText?.count ?? 0) + (windowText?.count ?? 0)
    }
}

/// The app to read from, in the form the reader can carry to a background
/// thread. `NSRunningApplication` is main-actor territory; three scalars are not.
struct AppTarget: Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?

    /// By name, for checking coverage in an app without switching to it —
    /// bringing Mail to the front to find out what parrot can read from Mail
    /// changes the thing being measured.
    @MainActor
    static func named(_ query: String) -> AppTarget? {
        let query = query.lowercased()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let match = apps.first { ($0.localizedName ?? "").lowercased() == query }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(query) }
            ?? apps.first { ($0.bundleIdentifier ?? "").lowercased().contains(query) }
        guard let match else { return nil }
        return AppTarget(
            pid: match.processIdentifier,
            name: match.localizedName ?? query,
            bundleID: match.bundleIdentifier
        )
    }

    @MainActor
    static func running() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted()
    }

    @MainActor
    static func frontmost() -> AppTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Reading our own settings window would be reading the user's answer
        // back to them, and it is never what they meant.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AppTarget(
            pid: app.processIdentifier,
            name: app.localizedName ?? "an app",
            bundleID: app.bundleIdentifier
        )
    }
}

/// Walks the accessibility tree of the frontmost app and returns the readable
/// parts of it.
///
/// Blocking, and deliberately not `@MainActor`: every call here is IPC into
/// *another* process's runloop, so a hung app would take parrot's main thread
/// with it. Callers run it off-main, and it holds itself to a deadline.
enum ScreenReader {
    struct Limits: Equatable {
        /// Character budget for the window text. The selection and the focused
        /// field are never truncated — they're small, and they're the point.
        var maxCharacters: Int
        /// Nodes visited before the walk gives up. A mail client's thread view
        /// can be tens of thousands of elements deep.
        var maxNodes: Int
        /// Deep on purpose. Electron stacks 7–9 container levels above its web
        /// content before any of the app's own markup starts, and a shallower
        /// cap spends the whole budget on shell chrome and returns nothing.
        var maxDepth: Int
        /// Wall-clock stop. The real backstop: node count says nothing about
        /// how slow a given app answers.
        var deadline: TimeInterval
        /// Ask Chromium apps to build an accessibility tree. Chrome, Edge,
        /// Slack, VS Code and Discord expose nothing at all without it.
        var enhanceChromium: Bool

        static let `default` = Limits(
            maxCharacters: 6000,
            maxNodes: 4000,
            maxDepth: 40,
            deadline: 1.5,
            enhanceChromium: true
        )
    }

    /// An app whose windows are never read, whatever the settings say. A
    /// password manager's window is a list of passwords; there is no prompt
    /// worth the risk of shipping one to a model.
    struct AlwaysExcluded: Identifiable, Equatable {
        /// What settings calls it. `com.agilebits.onepassword7` is not an
        /// answer to "which apps are excluded".
        let name: String
        /// Matched against the app's own name, lowercased, by substring. Catches
        /// versions and forks whose bundle id we've never seen.
        let fragment: String
        /// Every id the app has shipped under, matched exactly. An id survives a
        /// rename and a localised name, which the fragment does not.
        let bundleIDs: [String]

        var id: String { name }
    }

    static let alwaysExcluded: [AlwaysExcluded] = [
        AlwaysExcluded(
            name: "1Password",
            fragment: "1password",
            bundleIDs: [
                "com.1password.1password", "com.agilebits.onepassword7",
                "com.agilebits.onepassword",
            ]
        ),
        AlwaysExcluded(
            name: "Bitwarden",
            fragment: "bitwarden",
            bundleIDs: ["com.bitwarden.desktop"]
        ),
        AlwaysExcluded(
            name: "LastPass",
            fragment: "lastpass",
            bundleIDs: ["com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop"]
        ),
        AlwaysExcluded(
            name: "Dashlane",
            fragment: "dashlane",
            bundleIDs: ["com.dashlane.Dashlane", "com.dashlane.dashlanephoenix"]
        ),
        AlwaysExcluded(
            name: "KeePass",
            fragment: "keepass",
            bundleIDs: ["org.keepassxc.keepassxc", "com.kyleduo.KeePassium"]
        ),
        AlwaysExcluded(
            name: "Keychain Access",
            fragment: "keychain access",
            bundleIDs: ["com.apple.keychainaccess"]
        ),
        AlwaysExcluded(
            name: "Login window",
            fragment: "loginwindow",
            bundleIDs: ["com.apple.loginwindow"]
        ),
        AlwaysExcluded(
            name: "Parrot",
            fragment: "parrot",
            bundleIDs: ["com.digimata.parrot"]
        ),
    ]

    static func isExcluded(_ target: AppTarget) -> Bool {
        let name = target.name.lowercased()
        let bundleID = target.bundleID?.lowercased()
        return alwaysExcluded.contains { entry in
            if name.contains(entry.fragment) { return true }
            guard let bundleID else { return false }
            return entry.bundleIDs.contains { $0.lowercased() == bundleID }
        }
    }

    // MARK: - Capture

    static func capture(_ target: AppTarget, limits: Limits = .default) -> ScreenContext {
        guard !isExcluded(target) else {
            return .skipped(.excludedApp, app: target.name, bundleID: target.bundleID)
        }
        guard AXIsProcessTrusted() else {
            return .skipped(.noAccessibility, app: target.name, bundleID: target.bundleID)
        }

        // AX calls mint autoreleased objects, and this runs on a pooled
        // background thread that outlives any one walk. Without the pool they
        // accumulate for the life of the process.
        return autoreleasepool {
            captureInner(target, limits: limits)
        }
    }

    private static func captureInner(_ target: AppTarget, limits: Limits) -> ScreenContext {
        let started = Date()
        let app = AXUIElementCreateApplication(target.pid)
        // Without this a wedged app blocks the calling thread indefinitely.
        AXUIElementSetMessagingTimeout(app, 0.2)

        let focused = element(app, kAXFocusedUIElementAttribute)

        if limits.enhanceChromium {
            // Done before the tree is read, and at most once per app per
            // window — see `ChromiumAccessibility`.
            let settled = ChromiumAccessibility.enable(
                app: app, pid: target.pid, focusIsEditable: isEditable(focused)
            )
            if settled {
                // Chromium materialises the tree asynchronously after the flag
                // is written. Without a settle, the first read of a browser
                // comes back empty — and the first read is the one that counts.
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        // Re-read: enabling the tree can replace the focused element wholesale.
        let focusedNow = element(app, kAXFocusedUIElementAttribute) ?? focused
        let selection = focusedNow.flatMap { text($0, kAXSelectedTextAttribute) }
        // The field's own contents, but only from something that is actually a
        // text field — `AXValue` on a slider is a number, and on a table it is
        // whatever the app felt like.
        let focusedText = focusedNow.flatMap { element -> String? in
            guard isEditable(element), !isSecure(element) else { return nil }
            return text(element, kAXValueAttribute)
        }

        guard let window = focusedWindow(app) else {
            return ScreenContext(
                app: target.name, bundleID: target.bundleID, windowTitle: nil,
                selection: selection, focusedText: focusedText, windowText: nil,
                truncated: false, skipped: .noWindow,
                elapsed: Date().timeIntervalSince(started)
            )
        }
        AXUIElementSetMessagingTimeout(window, 0.2)

        var walk = Walk(limits: limits, started: started, windowFrame: frame(window))
        walk.visit(window, depth: 0)

        return ScreenContext(
            app: target.name,
            bundleID: target.bundleID,
            windowTitle: string(window, kAXTitleAttribute),
            selection: selection,
            // A field whose whole contents are selected would otherwise be sent
            // twice, under two labels that contradict each other.
            focusedText: focusedText == selection ? nil : focusedText,
            windowText: walk.joined,
            truncated: walk.truncated,
            skipped: nil,
            elapsed: Date().timeIntervalSince(started),
            filtered: walk.rejected.summary,
            roleHistogram: walk.rejected.visitedRoles
        )
    }

    /// Four tiers, because no single attribute is reliable across apps: an
    /// Electron app can report no focused window while plainly having one.
    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        if let window = element(app, kAXFocusedWindowAttribute) { return window }
        if let main = element(app, kAXMainWindowAttribute) { return main }
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let windowish: Set<String> = [kAXWindowRole, kAXSheetRole, kAXDrawerRole]
        return windows.first { windowish.contains(string($0, kAXRoleAttribute) ?? "") }
            ?? windows.first
    }

    // MARK: - The walk

    /// Depth-first, so the text comes out in reading order rather than in
    /// whatever order the harvest happened to finish in. AX child order *is*
    /// reading order in practice; sorting by geometry does worse.
    private struct Walk {
        let limits: Limits
        let started: Date
        let windowFrame: CGRect?

        private var lines: [String] = []
        private var seen: Set<String> = []
        private var characters = 0
        private var nodes = 0
        private(set) var truncated = false
        /// What each rule threw away. Every filter here is a guess about how
        /// some app models its UI, and a guess that silently drops the content
        /// is indistinguishable from an app that had none.
        private(set) var rejected = Rejections()

        struct Rejections: Equatable {
            var tooShort = 0
            var duplicate = 0
            var offscreen = 0
            var prunedRoles: [String: Int] = [:]

            /// Nodes the walk actually reached. The number that tells "the
            /// filter dropped it" apart from "the walk never got there".
            var visited = 0
            var visitedRoles: [String: Int] = [:]
            var harvested = 0

            var summary: String {
                var parts: [String] = ["\(visited) nodes", "\(harvested) kept"]
                if tooShort > 0 { parts.append("\(tooShort) too short") }
                if duplicate > 0 { parts.append("\(duplicate) duplicate") }
                if offscreen > 0 { parts.append("\(offscreen) offscreen") }
                let pruned = prunedRoles.values.reduce(0, +)
                if pruned > 0 {
                    let top = prunedRoles.sorted { $0.value > $1.value }
                        .prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    parts.append("\(pruned) pruned (\(top))")
                }
                return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
            }
        }

        /// A description longer than this is content; shorter is a label.
        /// Tuned against Slack message rows (60–200 chars) versus container
        /// labels like "Channel list" and "Home".
        static let selfDescribingThreshold = 40

        init(limits: Limits, started: Date, windowFrame: CGRect?) {
            self.limits = limits
            self.started = started
            self.windowFrame = windowFrame
        }

        var joined: String? {
            let kept = ScreenReader.dropContainedLines(lines)
            return kept.isEmpty ? nil : kept.joined(separator: "\n")
        }

        mutating func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= limits.maxDepth, !truncated else { return }
            nodes += 1
            rejected.visited = nodes
            guard nodes <= limits.maxNodes else {
                truncated = true
                return
            }
            // A tight loop of AX IPC starves the window server's own event
            // delivery — the keyboard and mouse visibly stutter without this.
            if nodes % 100 == 0 { sched_yield() }
            // Checked every node rather than every N: one `Date()` is nothing
            // next to the cross-process round trip that follows it.
            guard Date().timeIntervalSince(started) < limits.deadline else {
                truncated = true
                return
            }

            let role = string(element, kAXRoleAttribute) ?? ""
            rejected.visitedRoles[role, default: 0] += 1
            guard !ScreenReader.skippedRoles.contains(role) else {
                rejected.prunedRoles[role, default: 0] += 1
                return
            }

            if ScreenReader.textRoles.contains(role) {
                harvest(element, preferValue: true)
                // A text node's children are its runs and attachments, which
                // repeat what we just took.
                return
            }

            // A container that describes itself in full is the best version of
            // its own subtree. Slack labels each message row
            // "Sara Rekvik: …the message… Today at 10:23" while the leaves
            // below carry only the bare words — so taking the leaves loses who
            // said it, which is the one thing a reply cannot do without.
            //
            // Long descriptions only. A short one is a label ("Home", "Channel
            // list"), and swallowing a subtree on the strength of that would
            // lose everything under it.
            // A container that describes itself in full is often the best
            // version of its own subtree. Slack labels each message row
            // "Sara Rekvik: …the message… Today at 10:23" while the leaves
            // below carry only the bare words — so taking only the leaves loses
            // who said it, which is the one thing a reply cannot do without.
            //
            // Both are taken, and the overlap is resolved at the end by
            // dropping any line another line already contains. Deciding here
            // instead — swallow the subtree, or skip the summary — needs a rule
            // that can tell a message row from the window's root container, and
            // length is not that rule: a web area's title is the window title,
            // and returning early on it drops the entire page.
            if ScreenReader.containerRoles.contains(role) {
                harvestValueOnly(element)
                if let described = text(element, kAXDescriptionAttribute)
                    ?? text(element, kAXTitleAttribute),
                   described.count >= Self.selfDescribingThreshold {
                    append(described, from: element)
                }
            }

            guard let children = ScreenReader.children(element) else { return }
            // Electron stacks its shell containers above the web content, and
            // counting them against the depth budget leaves nothing for the
            // app's own markup — the text is always below this line, never
            // above it.
            let next = role == "AXWebArea" ? 0 : depth + 1
            for child in children {
                visit(child, depth: next)
                if truncated { return }
            }
        }

        private mutating func harvestValueOnly(_ element: AXUIElement) {
            guard let raw = text(element, kAXValueAttribute) else { return }
            append(raw, from: element)
        }

        private mutating func harvest(_ element: AXUIElement, preferValue: Bool) {
            guard !isSecure(element) else { return }
            guard let raw = text(element, kAXValueAttribute)
                ?? text(element, kAXTitleAttribute)
                ?? text(element, kAXDescriptionAttribute)
            else { return }
            append(raw, from: element)
        }

        private mutating func append(_ raw: String, from element: AXUIElement) {
            let line = ScreenReader.stripAccessibilityHints(raw)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // One- and two-character fragments are icon labels, list bullets
            // and separators — never content.
            guard line.count > 2 else {
                rejected.tooShort += 1
                return
            }
            // Sidebars, tab bars and repeated column headers say the same
            // things over and over; the model gains nothing from the tenth copy.
            guard seen.insert(line).inserted else {
                rejected.duplicate += 1
                return
            }
            guard isOnScreen(element) else {
                rejected.offscreen += 1
                return
            }

            guard characters + line.count <= limits.maxCharacters else {
                truncated = true
                return
            }
            characters += line.count
            rejected.harvested += 1
            lines.append(line)
        }

        /// Drops what is collapsed to nothing or sits outside the window.
        ///
        /// Asked only of nodes about to be harvested — asking it of every node
        /// would double the round trips for containers whose text we never take.
        ///
        /// Known limit, inherited from the API rather than chosen: this is
        /// window-level, not viewport-level. Text scrolled out of a scroll area
        /// still reports a frame inside the window, so scrollback survives the
        /// filter. The character budget is what actually bounds those.
        private func isOnScreen(_ element: AXUIElement) -> Bool {
            guard let rect = ScreenReader.frame(element) else {
                // An app that doesn't publish geometry still publishes text.
                // Keeping it beats dropping the whole app's content.
                return true
            }
            guard rect.width > 1, rect.height > 1 else { return false }
            guard let windowFrame else { return true }
            // Any overlap counts. Strict containment would drop the first and
            // last line of every scroll area.
            return rect.intersects(windowFrame)
        }
    }

    // MARK: - Chromium

    /// Chrome, Edge, and every Electron app ship their accessibility tree
    /// switched off and build it only when a client asks. Two different
    /// switches, because the two families answer to different ones:
    ///
    /// - `AXManualAccessibility` is Electron's, and is the safe one.
    /// - `AXEnhancedUserInterface` is what VoiceOver sets, and is the only thing
    ///   Chrome itself listens to.
    ///
    /// Both are no-ops on a native app. Neither is set casually:
    ///
    /// 1. **At most once per app per window of time.** Writing
    ///    `AXEnhancedUserInterface` makes Chromium rebuild its tree
    ///    synchronously, and that rebuild can commit a pending IME composition
    ///    or autocomplete suggestion into the focused field. Squawk aims at
    ///    focused text fields, so doing this on every recording would
    ///    eventually type something the user didn't.
    /// 2. **Never `AXEnhancedUserInterface` into an editable field.** It
    ///    advertises full screen-reader mode, which is the flag most likely to
    ///    disturb an input the user is in the middle of.
    private enum ChromiumAccessibility {
        private static let lock = NSLock()
        private static var lastPoked: [pid_t: Date] = [:]
        /// Long enough that a burst of squawks pokes once; short enough that an
        /// app relaunched into the same pid still gets asked.
        private static let ttl: TimeInterval = 300

        /// Returns whether anything was actually written — the caller only
        /// needs to wait for a settle when it was.
        static func enable(app: AXUIElement, pid: pid_t, focusIsEditable: Bool) -> Bool {
            lock.lock()
            let recent = lastPoked[pid].map { Date().timeIntervalSince($0) < ttl } ?? false
            if !recent { lastPoked[pid] = Date() }
            lock.unlock()
            guard !recent else { return false }

            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue
            )
            if !focusIsEditable {
                AXUIElementSetAttributeValue(
                    app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
                )
            }
            return true
        }

        static func forget(pid: pid_t) {
            lock.lock()
            lastPoked[pid] = nil
            lock.unlock()
        }
    }

    /// Testing seam — `parrot context` has to be able to ask twice in a row.
    static func forgetChromiumState(pid: pid_t) {
        ChromiumAccessibility.forget(pid: pid)
    }

    /// The same poke, for `RosterReader`.
    ///
    /// It walks the same Electron apps for a different reason and needs the tree
    /// switched on exactly as much — and needs it to go through the same
    /// once-per-app-per-window-of-time gate, so a squawk and a roster read in the
    /// same minute poke Chromium once between them rather than twice.
    static func enableChromium(app: AXUIElement, pid: pid_t, focusIsEditable: Bool) -> Bool {
        ChromiumAccessibility.enable(app: app, pid: pid, focusIsEditable: focusIsEditable)
    }

    // MARK: - Diagnostics

    /// The unfiltered tree, roles and all. Every filter in here is a guess about
    /// how some app models its UI, and the only way to check a guess is to look
    /// at the thing it was guessing about.
    static func dumpTree(_ target: AppTarget, limits: Limits = .default) -> String {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if limits.enhanceChromium {
            let focused = element(app, kAXFocusedUIElementAttribute)
            if ChromiumAccessibility.enable(
                app: app, pid: target.pid, focusIsEditable: isEditable(focused)
            ) {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        var out: [String] = ["\(target.name) (\(target.bundleID ?? "?"))"]
        guard let window = focusedWindow(app) else {
            let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
            out.append("no focused window · app reports \(windows) window(s)")
            return out.joined(separator: "\n")
        }

        var nodes = 0
        func walk(_ element: AXUIElement, depth: Int, indent: Int) {
            guard depth <= limits.maxDepth, nodes < limits.maxNodes else { return }
            nodes += 1
            let role = string(element, kAXRoleAttribute) ?? "?"
            let subrole = string(element, kAXSubroleAttribute).map { " /\($0)" } ?? ""
            let body = text(element, kAXValueAttribute)
                ?? text(element, kAXTitleAttribute)
                ?? text(element, kAXDescriptionAttribute)
            let preview = body.map {
                " · " + String($0.prefix(70)).replacingOccurrences(of: "\n", with: "⏎")
            } ?? ""
            let kids = children(element)?.count ?? 0
            out.append(
                String(repeating: "  ", count: min(indent, 30))
                    + "\(role)\(subrole) [\(kids)]\(preview)"
            )
            let next = role == "AXWebArea" ? 0 : depth + 1
            for child in children(element) ?? [] {
                walk(child, depth: next, indent: indent + 1)
            }
        }
        walk(window, depth: 0, indent: 0)
        out.append("\n\(nodes) nodes visited")
        return out.joined(separator: "\n")
    }

    // MARK: - Role tables

    /// Chrome and Electron bury text under long chains of `AXGroup` and
    /// `AXUnknown`, so descent is a denylist rather than an allowlist: an
    /// allowlist silently returns nothing at all in exactly the apps that
    /// matter most.
    static let skippedRoles: Set<String> = [
        kAXToolbarRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole,
        kAXMenuItemRole, kAXScrollBarRole, kAXSplitterRole, kAXGrowAreaRole,
        kAXImageRole, kAXSliderRole, kAXIncrementorRole, kAXProgressIndicatorRole,
        kAXBusyIndicatorRole, kAXColorWellRole, kAXValueIndicatorRole,
        kAXRulerRole, kAXRulerMarkerRole, "AXSecureTextField",
    ]

    /// Roles whose text is worth taking. `AXStaticText` is the bulk of it —
    /// every message in a thread, every line of a document. Links and cells
    /// carry the content of web apps and mail lists, which is most of the
    /// interesting cases.
    static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
        kAXCellRole, "AXLink", "AXHeading",
    ]

    /// Containers that sometimes hold text of their own. Their `AXValue` is
    /// taken; their title and description are not, because their children say
    /// the same thing better.
    static let containerRoles: Set<String> = ["AXWebArea", kAXGroupRole]

    /// Where a half-written reply lives.
    static let editableRoles: Set<String> = [
        kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField",
    ]

    static func isEditable(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        if let role = string(element, kAXRoleAttribute), editableRoles.contains(role) {
            return true
        }
        return copy(element, "AXEditable") as? Bool ?? false
    }

    // MARK: - AX plumbing

    /// Every accessor here type-checks before it converts. AX will hand back a
    /// number where the documentation promises a string, and a wrong-typed
    /// force-cast is a crash in someone else's app's UI.
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copy(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement]? {
        copy(element, kAXChildrenAttribute) as? [AXUIElement]
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    /// Screen-absolute, from position + size. `AXFrame` is not published by
    /// every app; those two are.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// A string attribute, but only if there is something in it.
    static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = string(element, attribute) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes lines another line already says.
    ///
    /// A container's summary and its leaves both get harvested, so a Slack
    /// message arrives twice: once as "Sara Rekvik: Kvarstår det vad vi vet?
    /// Today at 10:23" and once as the bare "Kvarstår det vad vi vet?". Keeping
    /// the longer one keeps the attribution and the timestamp; dropping the
    /// shorter one keeps the transcript from paying for both.
    ///
    /// Only lines of `minimumContainedLength` or more are eligible to be
    /// dropped. "Yes" is a substring of "Yesterday at 3:27" and is not the same
    /// statement.
    static let minimumContainedLength = 12

    static func dropContainedLines(_ lines: [String]) -> [String] {
        // Longest first, so a line is only ever compared against lines that
        // could actually contain it.
        let byLength = lines.enumerated().sorted { $0.element.count > $1.element.count }
        var kept: [(offset: Int, element: String)] = []
        for line in byLength {
            if line.element.count >= minimumContainedLength,
               kept.contains(where: { $0.element.contains(line.element) }) {
                continue
            }
            kept.append(line)
        }
        // Back into reading order.
        return kept.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// Instructions aimed at screen-reader users, which arrive glued onto the
    /// end of a label: "Monday, July 13th Press enter to select a date to jump
    /// to." The date is content; the rest is an instruction for a different
    /// kind of assistive technology, and to a language model it reads as
    /// something it is being asked to do.
    static let accessibilityHintMarkers = [
        " Press enter to", " Press Enter to", " Click to ", " Double-tap to ",
        " Use ⌥F1", " Use ⌘F1", " Use ^F1",
    ]

    static func stripAccessibilityHints(_ text: String) -> String {
        var text = text
        for marker in accessibilityHintMarkers {
            if let range = text.range(of: marker) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }
        return text
    }

    /// Password fields, at any depth, unconditionally. The one rule in here
    /// with no configuration attached to it.
    static func isSecure(_ element: AXUIElement) -> Bool {
        if let subrole = string(element, kAXSubroleAttribute),
           subrole == kAXSecureTextFieldSubrole {
            return true
        }
        // Some apps ship a plain text field and mark it only in the description.
        if let description = string(element, kAXRoleDescriptionAttribute)?.lowercased(),
           description.contains("secure") || description.contains("password") {
            return true
        }
        return false
    }
}

/// Free functions so the nested `Walk` can reach them without qualifying every
/// call site.
private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    ScreenReader.string(element, attribute)
}

private func text(_ element: AXUIElement, _ attribute: String) -> String? {
    ScreenReader.text(element, attribute)
}

private func isSecure(_ element: AXUIElement) -> Bool {
    ScreenReader.isSecure(element)
}
