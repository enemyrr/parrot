import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    enum State {
        case idle
        case recording
        case latched
        case transcribing
    }

    private static let recentCount = 10
    /// Roomier than the main menu would allow, since the submenu is its own
    /// column and nothing else competes for the width.
    private static let recentTitleLength = 60

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let recentMenu = NSMenu()
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelID: String
    private let store: TranscriptStore?

    init(modelID: String, store: TranscriptStore?) {
        self.modelID = modelID
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false

        super.init()

        menu.autoenablesItems = false
        menu.addItem(stateLabel)
        menu.addItem(modelLabel)

        if store != nil {
            menu.addItem(.separator())
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            // Populated on open via menuNeedsUpdate — no need to rebuild the
            // menu on every transcript, and it can never show stale entries.
            recentMenu.delegate = self
            recentMenu.autoenablesItems = false
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
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

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu, let store else { return }
        menu.removeAllItems()

        let entries = store.recent(Self.recentCount)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Click to copy", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            for entry in entries {
                let item = NSMenuItem(
                    title: Self.title(for: entry),
                    action: #selector(recentClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let open = NSMenuItem(
            title: "Open History File",
            action: #selector(openHistoryClicked),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let clear = NSMenuItem(
            title: "Clear History…",
            action: #selector(clearHistoryClicked),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !entries.isEmpty
        menu.addItem(clear)
    }

    private static func title(for entry: TranscriptEntry) -> String {
        let time = DateFormatter.menuStamp.string(from: entry.at)
        let flat = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let body = flat.count > recentTitleLength
            ? flat.prefix(recentTitleLength - 1) + "…"
            : flat
        return "\(time)   \(body)"
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
        } catch {
            FileHandle.standardError.write(Data("history clear failed: \(error)\n".utf8))
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

extension DateFormatter {
    /// Time only — the submenu never shows more than a day or two of entries
    /// in practice, and a full date would crowd the transcript.
    static let menuStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
