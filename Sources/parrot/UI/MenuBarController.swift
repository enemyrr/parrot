import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance, and is the way into the settings window — we run as `.accessory`,
/// so there is no dock icon and no window on launch.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    enum State {
        case idle
        case recording
        case latched
        case transcribing
    }

    /// What the engine underneath is doing. Separate from `State`, which is
    /// about the current utterance: a model can still be loading while nothing
    /// is being recorded, and that is exactly when the user wants to know.
    enum Engine {
        case loading
        case ready
        case failed
        case needsPermission
    }

    private static let recentCount = 10
    /// Roomier than the main menu would allow, since the submenu is its own
    /// column and nothing else competes for the width.
    private static let recentTitleLength = 60

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let recentMenu = NSMenu()
    private let recentItem: NSMenuItem
    private let microphoneMenu = NSMenu()
    private let microphoneItem: NSMenuItem
    private let statusLine: NSMenuItem

    private let openSettings: (SettingsPane) -> Void
    private let settings: SettingsStore
    private var store: TranscriptStore?
    private var engine: Engine = .loading
    private var state: State = .idle

    init(
        openSettings: @escaping (SettingsPane) -> Void,
        settings: SettingsStore,
        store: TranscriptStore?
    ) {
        self.openSettings = openSettings
        self.settings = settings
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // One status line, at the top. The model id and the cleanup provider
        // that used to sit here were read-only restatements of what the
        // settings window says better; whether parrot is actually working is
        // the one thing you can't find out anywhere else. Disabled while it's
        // fine — there is nothing to click — and clickable when it isn't,
        // because then there is.
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")

        super.init()

        menu.autoenablesItems = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Populated on open via menuNeedsUpdate — no need to rebuild the menu
        // on every transcript, and it can never show stale entries.
        recentMenu.delegate = self
        recentMenu.autoenablesItems = false
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        // Under Recent, above the microphone: it belongs with the transcripts,
        // not with the settings — it makes one rather than changes how they're
        // made.
        let transcribeFile = NSMenuItem(
            title: "Transcribe File…",
            action: #selector(transcribeFileClicked),
            keyEquivalent: ""
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)

        menu.addItem(.separator())

        // Same deal as Recent: built on open, because devices come and go while
        // the app is running and a menu built at launch would offer headphones
        // that were unplugged an hour ago. Sits with Settings rather than with
        // Recent — it's a setting you change, not a thing you read back.
        microphoneMenu.delegate = self
        microphoneMenu.autoenablesItems = false
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit parrot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton()
        setHistoryStore(store)
        setEngine(.loading)
    }

    // MARK: - Updates

    func setState(_ state: State) {
        self.state = state
        refreshStatusLine()
        configureButton()
    }

    func setEngine(_ engine: Engine) {
        self.engine = engine
        refreshStatusLine()
        configureButton()
    }

    /// Dot, label, and whether there's anything to do about it.
    private func refreshStatusLine() {
        let (color, text, action): (NSColor, String, Selector?) = {
            switch engine {
            case .failed:
                return (.systemRed, "Model didn't load — open Settings", #selector(openModelsClicked))
            case .needsPermission:
                return (.systemOrange, "Accessibility not granted — finish setup", #selector(openPermissionsClicked))
            case .loading:
                return (.secondaryLabelColor, "Starting up…", nil)
            case .ready:
                switch state {
                case .idle: return (.systemGreen, "Ready", nil)
                case .recording: return (.systemRed, "Recording", nil)
                case .latched: return (.systemRed, "Recording — hands-free", nil)
                case .transcribing: return (.systemBlue, "Transcribing…", nil)
                }
            }
        }()

        // An attributed title so the dot keeps its colour on a disabled item —
        // a plain title would be drawn in one flat grey, and the colour is
        // doing as much work here as the word is.
        let title = NSMutableAttributedString(string: "\u{25CF}  \(text)")
        title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        title.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 1, length: title.length - 1)
        )
        title.addAttribute(
            .font,
            value: NSFont.menuFont(ofSize: 0),
            range: NSRange(location: 0, length: title.length)
        )
        statusLine.attributedTitle = title
        statusLine.action = action
        statusLine.target = action == nil ? nil : self
        statusLine.isEnabled = action != nil
    }

    func setHistoryStore(_ store: TranscriptStore?) {
        self.store = store
        recentItem.isHidden = store == nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === microphoneMenu {
            rebuildMicrophoneMenu(menu)
            return
        }
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

        let all = NSMenuItem(
            title: "Show All…",
            action: #selector(openHistoryPaneClicked),
            keyEquivalent: ""
        )
        all.target = self
        menu.addItem(all)
    }

    /// The device list, with a tick on the one recordings come from.
    ///
    /// "System Default" is first and names the device it currently resolves to,
    /// because "System Default" on its own doesn't answer the question anyone
    /// opens this menu with — which microphone am I on?
    private func rebuildMicrophoneMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let selected = settings.settings.audio.inputDeviceUID
        let devices = AudioDevices.inputs()

        let systemDefault = AudioDevices.systemDefaultInput()
        let followTitle = systemDefault.map { "System Default (\($0.name))" } ?? "System Default"
        menu.addItem(microphoneChoice(title: followTitle, uid: "", selected: selected))

        if !devices.isEmpty {
            menu.addItem(.separator())
            for device in devices {
                menu.addItem(microphoneChoice(title: device.name, uid: device.uid, selected: selected))
            }
        }

        // A chosen device that isn't plugged in gets said out loud. Capture
        // falls back to the system default, and without this row the menu would
        // show no tick at all and look like the setting had lost itself.
        if !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) {
            menu.addItem(.separator())
            let missing = NSMenuItem(
                title: "Chosen microphone unavailable — using the default",
                action: nil,
                keyEquivalent: ""
            )
            missing.isEnabled = false
            menu.addItem(missing)
        }
    }

    private func microphoneChoice(title: String, uid: String, selected: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(microphoneClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = uid
        item.state = uid == selected ? .on : .off
        return item
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

    /// The icon carries the state on its own — the menu has to be opened to
    /// read anything else, and the point of a status item is the glance.
    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = ParrotGlyph.image(size: 16)

        switch (engine, state) {
        case (.needsPermission, _), (.failed, _):
            button.alphaValue = 1
            button.contentTintColor = .systemOrange
        case (.loading, _):
            button.alphaValue = 0.45
            button.contentTintColor = nil
        case (_, .recording), (_, .latched):
            button.alphaValue = 1
            button.contentTintColor = .controlAccentColor
        case (_, .transcribing):
            button.alphaValue = 0.6
            button.contentTintColor = .controlAccentColor
        case (_, .idle):
            button.alphaValue = 1
            button.contentTintColor = nil
        }
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

    /// Writes straight through the store, so it persists and the daemon picks
    /// it up the same way it picks up a change made in the settings window.
    /// Takes effect on the next recording — swapping the device out from under
    /// one in flight would end it with half a sentence.
    @objc private func microphoneClicked(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        settings.settings.audio.inputDeviceUID = uid
    }

    /// Picks the file here, then hands it to the pane that can show a progress
    /// line and a transcript. The window comes forward either way — a job with
    /// nowhere to report is worse than no job.
    @objc private func transcribeFileClicked() {
        guard let url = FileTranscriptionJob.chooseFile() else { return }
        openSettings(.transcribe)
        FileTranscriptionJob.shared.start(url: url)
    }

    @objc private func openSettingsClicked() { openSettings(.home) }
    @objc private func openModelsClicked() { openSettings(.models) }
    @objc private func openPermissionsClicked() { openSettings(.permissions) }
    @objc private func openHistoryPaneClicked() { openSettings(.history) }

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
