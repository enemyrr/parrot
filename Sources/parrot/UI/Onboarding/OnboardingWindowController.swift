import AppKit
import SwiftUI

/// Owns the first-run window.
///
/// Its own window rather than a pane in Settings, and deliberately not
/// resizable: this is one path with an end, and every affordance the settings
/// window has — a sidebar, ten tabs, a status bar — is a way to leave it
/// half-finished.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// So the daemon doesn't stack a settings window on top of a setup that is
    /// already explaining the same problem.
    var isOpen: Bool { window?.isVisible ?? false }

    private override init() {
        super.init()
    }

    /// No default arguments: a default expression is evaluated outside the
    /// type's isolation, and `.shared` in one would be a main-actor access from
    /// a nonisolated context.
    func show(store: SettingsStore, catalog: ModelCatalog, context: SettingsContext) {
        let window = self.window ?? makeWindow()
        window.contentView = NSHostingView(rootView: OnboardingView(
            store: store,
            catalog: catalog,
            context: context,
            finish: { [weak self] in self?.window?.close() }
        ))
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up parrot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closed by the red button and finished by Done both count. Reopening
        // this on every launch until someone reaches the last step would be
        // nagging, and `parrot setup` brings it back for anyone who wants it.
        SettingsStore.hasCompletedOnboarding = true
        // The window outlives its close (`isReleasedWhenClosed = false`), so
        // SwiftUI never hears about it: `onDisappear` wouldn't run, and the
        // microphone the mic step opened would stay open. Dropping the hosting
        // view is what tears the hierarchy down; `show` rebuilds it.
        window?.contentView = nil
    }
}
