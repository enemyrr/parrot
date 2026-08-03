import AppKit
import ApplicationServices
import Foundation

/// Walks a window for the *names* in it.
///
/// A second walk rather than a mode on `ScreenReader`, and the difference is the
/// point. `ScreenReader` collects prose in reading order and joins it into
/// something a model can read — it produces the contents of the window. This
/// collects short labels with their positions and throws the prose away, and
/// what comes out the far end is a list of channel names and filenames. That
/// distinction is the reason dictation is allowed to run this at all: dictation
/// never sends what is on your screen anywhere, and a roster is not what is on
/// your screen.
///
/// Blocking and not `@MainActor`, for the same reason as `ScreenReader`: every
/// call is IPC into another process's runloop.
enum RosterReader {
    struct Limits: Equatable {
        var maxNodes: Int
        var maxDepth: Int
        /// Wall-clock stop. Tighter than squawk's, because this one runs on the
        /// dictation path — where it is racing the user finishing a sentence,
        /// not a model that is going to take seconds anyway.
        var deadline: TimeInterval
        /// Labels kept before the walk stops collecting. A roster is tens of
        /// names; anything past this is an app whose whole document is made of
        /// short lines, and reading more of it finds no more names.
        var maxCandidates: Int
        /// Longest label kept. Long enough for a Slack message row, whose
        /// leading "Name:" is the strongest person signal there is, and short
        /// enough that nothing here is holding a paragraph.
        var maxNodeCharacters: Int
        /// Longest *text area* kept, which is a different number for a different
        /// reason. A native editor — Xcode, a terminal — publishes its whole
        /// document as one node's value, and the label budget would clip that to
        /// the first three lines. This is what makes identifier mining work
        /// anywhere outside a Chromium app.
        var maxTextAreaCharacters: Int
        var enhanceChromium: Bool

        static let `default` = Limits(
            maxNodes: 3000,
            maxDepth: 40,
            deadline: 0.9,
            maxCandidates: 1200,
            maxNodeCharacters: 300,
            maxTextAreaCharacters: 6000,
            enhanceChromium: true
        )
    }

    static func read(
        _ target: AppTarget,
        integration: AppIntegration,
        limits: Limits = .default
    ) -> AppRoster {
        readKeepingScan(target, integration: integration, limits: limits).roster
    }

    /// `read`, handing back the walk it classified.
    ///
    /// For `parrot roster --nodes`: printing the labels from a second walk
    /// would explain a roster nobody read — the window scrolls, and a Chromium
    /// tree gets rebuilt between the two.
    static func readKeepingScan(
        _ target: AppTarget,
        integration: AppIntegration,
        limits: Limits = .default
    ) -> (roster: AppRoster, scan: RosterScan?) {
        guard !ScreenReader.isExcluded(target) else {
            return (.failed(.excluded, integrationID: integration.id,
                            app: target.name, bundleID: target.bundleID), nil)
        }
        guard AXIsProcessTrusted() else {
            return (.failed(.noAccessibility, integrationID: integration.id,
                            app: target.name, bundleID: target.bundleID), nil)
        }
        // Same reason as `ScreenReader.capture`: AX mints autoreleased objects
        // and this runs on a pooled thread that outlives the walk.
        return autoreleasepool { readInner(target, integration: integration, limits: limits) }
    }

    /// The text a text area is actually showing, by range.
    ///
    /// `AXValue` on an editor is the whole document; `AXVisibleCharacterRange`
    /// plus `AXStringForRange` is the viewport. The difference is the whole
    /// reason identifier mining works in Xcode: what is on screen is what the
    /// speaker is looking at and about to talk about, and the other 200KB is
    /// noise that would also blow the walk's time budget.
    ///
    /// Nil for anything that doesn't answer the range query — every Chromium app,
    /// which is why the caller falls back to the plain value.
    static func visibleText(_ element: AXUIElement, limit: Int) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXVisibleCharacterRangeAttribute as CFString, &rangeRef
        ) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0
        else { return nil }
        range.length = min(range.length, limit)

        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result
        ) == .success else { return nil }

        let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private static func walk(
        _ target: AppTarget,
        limits: Limits
    ) -> (scan: RosterScan, visited: Int, truncated: Bool)? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)

        if limits.enhanceChromium {
            let focused = ScreenReader.element(app, kAXFocusedUIElementAttribute)
            let settled = ScreenReader.enableChromium(
                app: app, pid: target.pid, focusIsEditable: ScreenReader.isEditable(focused)
            )
            // Chromium builds the tree asynchronously after the flag is written,
            // and every app this feature is for is Chromium.
            if settled { Thread.sleep(forTimeInterval: 0.15) }
        }

        guard let window = ScreenReader.focusedWindow(app) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.2)

        var walk = Walk(limits: limits, started: Date())
        walk.visit(window, depth: 0)

        return (
            scan: RosterScan(
                windowFrame: ScreenReader.frame(window),
                windowTitle: ScreenReader.text(window, kAXTitleAttribute),
                nodes: walk.nodes
            ),
            visited: walk.visited,
            truncated: walk.truncated
        )
    }

    private static func readInner(
        _ target: AppTarget,
        integration: AppIntegration,
        limits: Limits
    ) -> (roster: AppRoster, scan: RosterScan?) {
        let started = Date()
        guard let walked = walk(target, limits: limits) else {
            return (.failed(.noWindow, integrationID: integration.id,
                            app: target.name, bundleID: target.bundleID,
                            elapsed: Date().timeIntervalSince(started)), nil)
        }

        let entities = integration.classify(walked.scan)
        let elapsed = Date().timeIntervalSince(started)

        guard entities.count >= AppRoster.minimumEntities else {
            return (.failed(.nothingFound, integrationID: integration.id,
                            app: target.name, bundleID: target.bundleID,
                            nodes: walked.visited, elapsed: elapsed), walked.scan)
        }

        return (AppRoster(
            integrationID: integration.id,
            app: target.name,
            bundleID: target.bundleID,
            entities: entities,
            nodes: walked.visited,
            elapsed: elapsed,
            truncated: walked.truncated,
            unavailable: nil,
            note: RosterText.editorAccessNote(in: walked.scan)
        ), walked.scan)
    }

    /// Depth-first, collecting short labelled nodes and their frames.
    ///
    /// No deduplication and no containment pass, unlike `ScreenReader`'s walk:
    /// a repeated label is evidence here rather than noise — a name that shows
    /// up in the sidebar *and* over three messages is more likely to be a real
    /// name than one that appears once, and `AppIntegration.symbols` counts on
    /// exactly that.
    private struct Walk {
        let limits: Limits
        let started: Date

        private(set) var nodes: [RosterScan.Node] = []
        private(set) var visited = 0
        private(set) var truncated = false

        init(limits: Limits, started: Date) {
            self.limits = limits
            self.started = started
        }

        mutating func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= limits.maxDepth, !truncated else { return }
            visited += 1
            guard visited <= limits.maxNodes, nodes.count < limits.maxCandidates else {
                truncated = true
                return
            }
            // A tight loop of AX IPC starves the window server's event delivery.
            if visited % 100 == 0 { sched_yield() }
            guard Date().timeIntervalSince(started) < limits.deadline else {
                truncated = true
                return
            }

            let role = ScreenReader.string(element, kAXRoleAttribute) ?? ""
            guard !ScreenReader.skippedRoles.contains(role) else { return }
            guard !ScreenReader.isSecure(element) else { return }

            harvest(element, role: role)

            guard let children = ScreenReader.children(element) else { return }
            // Electron stacks shell containers above the web content; counting
            // them against the budget leaves nothing for the app's own markup.
            let next = role == "AXWebArea" ? 0 : depth + 1
            for child in children {
                visit(child, depth: next)
                if truncated { return }
            }
        }

        private mutating func harvest(_ element: AXUIElement, role: String) {
            let isTextArea = role == kAXTextAreaRole
            // A text area holds a document. What is worth mining is the part on
            // screen — asked for by range, so a 200KB source file costs one
            // viewport's worth of string rather than 200KB of it. Falls back to
            // the plain value for anything that doesn't answer the range query.
            let raw = (isTextArea ? RosterReader.visibleText(
                element, limit: limits.maxTextAreaCharacters
            ) : nil)
                ?? ScreenReader.text(element, kAXValueAttribute)
                ?? ScreenReader.text(element, kAXTitleAttribute)
                ?? ScreenReader.text(element, kAXDescriptionAttribute)
            guard var text = raw else { return }
            guard text.count > 1 else { return }
            let budget = isTextArea ? limits.maxTextAreaCharacters : limits.maxNodeCharacters
            if text.count > budget {
                text = String(text.prefix(budget))
            }
            nodes.append(RosterScan.Node(
                text: text,
                role: role,
                frame: ScreenReader.frame(element)
            ))
        }
    }
}

/// Whether each integration is currently working, remembered across dictations.
///
/// The failsafe, and the reason it has to be stateful: an integration that comes
/// back empty is not an error anyone can act on in the moment — the fix is to
/// stop paying for the walk and say so somewhere the user will see it. So empty
/// reads are counted, and after enough of them in a row the integration is
/// switched off for that app until something changes.
///
/// Deliberately *not* persisted. A stored "unavailable" would outlive the app
/// update that fixed it, and the cost of being wrong in the other direction is
/// one walk.
@MainActor
final class IntegrationMonitor: ObservableObject {
    /// One per process. The daemon writes it and the settings window reads it,
    /// and there is only ever one of each.
    static let shared = IntegrationMonitor()

    /// Consecutive empty reads before parrot stops asking. Three rather than
    /// one: an editor with no file open and a Slack window on the preferences
    /// screen are both legitimately empty, and neither means the integration is
    /// broken.
    ///
    /// `nonisolated` so `State`, which is a plain value anyone can hold, can
    /// answer `hasGivenUp` without hopping to the main actor for a constant.
    nonisolated static let failureLimit = 3

    struct State: Equatable {
        var lastResult: IntegrationUnavailable?
        var entityCount = 0
        var consecutiveFailures = 0
        var lastSeen: Date?
        /// The pid the last read was against. A different one means the app
        /// restarted — possibly into a version that works — so the count is
        /// dropped and it gets another go.
        var pid: pid_t?

        var hasGivenUp: Bool { consecutiveFailures >= IntegrationMonitor.failureLimit }
    }

    /// Keyed by integration id, not bundle id: Cursor and Windsurf are separate
    /// rows in settings and separate answers to "does this work on my machine".
    @Published private(set) var states: [String: State] = [:]

    func state(for integrationID: String) -> State {
        states[integrationID] ?? State()
    }

    /// Whether it is worth walking the window at all.
    func shouldRead(_ integration: AppIntegration, pid: pid_t) -> Bool {
        let state = state(for: integration.id)
        // A restart resets the verdict.
        if let last = state.pid, last != pid { return true }
        return !state.hasGivenUp
    }

    func record(_ roster: AppRoster, integrationID: String, pid: pid_t) {
        var state = state(for: integrationID)
        if let last = state.pid, last != pid { state.consecutiveFailures = 0 }
        state.pid = pid
        state.lastSeen = Date()
        state.lastResult = roster.unavailable
        state.entityCount = roster.entities.count
        if roster.isUsable {
            state.consecutiveFailures = 0
        } else if roster.unavailable == .nothingFound {
            // Only an empty walk counts. The others say something about the
            // machine rather than the app — no permission yet, no window open —
            // and giving up on those would leave the integration dead after the
            // user granted access.
            state.consecutiveFailures += 1
        }
        states[integrationID] = state
    }

    /// "Check again" in settings, and what a settings change calls.
    func reset(_ integrationID: String? = nil) {
        if let integrationID {
            states[integrationID] = nil
        } else {
            states.removeAll()
        }
    }

    /// What the settings row shows. Folds the sticky give-up state into the
    /// reason, so the UI has one thing to render rather than two.
    func availability(
        for integration: AppIntegration,
        settings: IntegrationSettings
    ) -> IntegrationUnavailable? {
        guard settings.enabled else { return .off }
        guard settings.isEnabled(integration.id) else { return .off }
        let state = state(for: integration.id)
        if state.hasGivenUp { return .gaveUp }
        return state.lastResult
    }
}
