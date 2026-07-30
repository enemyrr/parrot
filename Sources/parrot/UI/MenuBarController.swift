import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    enum State {
        case idle
        case recording
        case latched
        case transcribing
    }

    private static let recentCount = 10
    private static let recentTitleLength = 48

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelID: String
    private let store: TranscriptStore?
    /// Index of the first recent-transcript row, so we can rebuild just that
    /// section without reconstructing the whole menu.
    private var recentSectionStart = 0
    private var recentItemCount = 0

    init(modelID: String, store: TranscriptStore?) {
        self.modelID = modelID
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        if store != nil {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            recentSectionStart = menu.numberOfItems

            menu.addItem(.separator())
            let open = NSMenuItem(
                title: "Open history file",
                action: #selector(openHistoryClicked),
                keyEquivalent: ""
            )
            open.target = self
            menu.addItem(open)

            let clear = NSMenuItem(
                title: "Clear history",
                action: #selector(clearHistoryClicked),
                keyEquivalent: ""
            )
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton()
        reloadRecents()
    }

    func setState(_ state: State) {
        switch state {
        case .idle:
            stateLabel.title = "idle · hold fn to dictate"
        case .recording:
            stateLabel.title = "● recording"
        case .latched:
            stateLabel.title = "● recording (hands-free · tap fn to stop)"
        case .transcribing:
            stateLabel.title = "transcribing…"
        }
    }

    /// Rebuild the Recent section from the store. Cheap — the store keeps the
    /// log in a file we only read the tail of.
    func reloadRecents() {
        guard let store else { return }
        for _ in 0..<recentItemCount {
            menu.removeItem(at: recentSectionStart)
        }
        recentItemCount = 0

        let entries = store.recent(Self.recentCount)
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "  (nothing yet)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.insertItem(empty, at: recentSectionStart)
            recentItemCount = 1
            return
        }

        for (offset, entry) in entries.enumerated() {
            let item = NSMenuItem(
                title: Self.truncate(entry.text),
                action: #selector(recentClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            menu.insertItem(item, at: recentSectionStart + offset)
        }
        recentItemCount = entries.count
    }

    private static func truncate(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > recentTitleLength else { return flat }
        return flat.prefix(recentTitleLength - 1) + "…"
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Actions

    /// Copy rather than re-inject: by the time the menu closes, focus has
    /// returned to whatever app was underneath, and typing into it uninvited
    /// is a worse surprise than a clipboard write.
    @objc private func recentClicked(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openHistoryClicked() {
        guard let store else { return }
        NSWorkspace.shared.selectFile(store.path, inFileViewerRootedAtPath: "")
    }

    @objc private func clearHistoryClicked() {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Clear dictation history?"
        alert.informativeText = "Every transcript in \(store.path) will be deleted. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.clear()
            reloadRecents()
        } catch {
            FileHandle.standardError.write(Data("history clear failed: \(error)\n".utf8))
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
