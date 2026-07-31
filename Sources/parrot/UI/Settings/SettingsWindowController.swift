import AppKit
import SwiftUI

/// Owns the settings window.
///
/// A window rather than a `Settings` scene because parrot has no `App` — it is
/// an `NSApplication` running as an accessory so it can live in the menu bar
/// with no dock icon. That also means nothing brings the window forward for
/// free: activating the app is this class's job.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Filled in by the daemon so the panes can reach a live engine. Left nil
    /// by `parrot settings`, which opens the same window with nothing running.
    let context = SettingsContext()

    private var window: NSWindow?
    private var pane: SettingsPane = .general

    private override init() {
        super.init()
    }

    func show(pane: SettingsPane = .general) {
        self.pane = pane
        let window = window ?? makeWindow()
        // Rebuilding the root view is what makes `show(pane:)` able to select a
        // pane on an already-open window — the selection is `@State`, so it
        // needs a fresh view to take a new initial value.
        window.contentView = NSHostingView(rootView: rootView(pane: pane))
        window.makeKeyAndOrderFront(nil)
        window.center(ifNeverPlaced: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rootView(pane: SettingsPane) -> some View {
        SettingsRootView(
            store: SettingsStore.shared,
            catalog: ModelCatalog.shared,
            context: context,
            pane: pane
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "parrot"
        // The sidebar carries its own identity, so the title bar is there for
        // the traffic lights and the drag region only.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("parrot.settings")
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // A preview left running would keep the microphone hot and the pill on
        // screen after the window that started it has gone.
        context.endOverlayPreview?()
        // The window is kept alive (`isReleasedWhenClosed = false`), so closing
        // it doesn't reach SwiftUI on its own: `onDisappear` never runs and the
        // panes' teardown never happens — the shortcut recorder's local event
        // monitor would go on swallowing keystrokes with no window on screen,
        // and the permissions poller would keep shelling out every two seconds.
        // Dropping the hosting view is what tears the hierarchy down. `show`
        // rebuilds it.
        window?.contentView = nil
    }
}

private extension NSWindow {
    /// `center()` on every open would undo the position the user dragged it to,
    /// which `setFrameAutosaveName` went to the trouble of remembering.
    func center(ifNeverPlaced: Bool) {
        guard ifNeverPlaced, frame.origin == .zero else { return }
        center()
    }
}
