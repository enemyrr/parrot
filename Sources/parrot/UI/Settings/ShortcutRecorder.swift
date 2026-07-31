import AppKit
import SwiftUI

/// Click, press the keys you want, done — the shortcut field every Mac app has.
///
/// It listens with a *local* event monitor, so it only ever sees keystrokes
/// aimed at this window. The global tap that actually watches for the hotkey
/// needs Accessibility; recording one must not, or setting a shortcut would be
/// blocked on the permission you are trying to set a shortcut in order to use.
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey

    @State private var recording = false
    @State private var heldModifiers: HotkeyModifiers = []
    @State private var rejected: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if let rejected {
                Text(rejected)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .trailing)
            }

            Button(action: toggle) {
                Text(fieldLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(recording
                                ? Color.accentColor.opacity(0.16)
                                : SettingsPalette.keycapFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                recording ? Color.accentColor : SettingsPalette.keycapBorder,
                                lineWidth: recording ? 1.5 : 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(recording ? "Press the keys you want, or Esc to cancel" : "Record a shortcut")
        }
        .animation(.easeOut(duration: 0.15), value: recording)
        .onDisappear(perform: stop)
    }

    private var fieldLabel: String {
        if recording {
            return heldModifiers.isEmpty ? "Press keys…" : heldModifiers.symbols
        }
        return hotkey.isPreset ? "Record shortcut" : hotkey.displayLabel
    }

    // MARK: - Recording

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        rejected = nil
        heldModifiers = []
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Swallow the event either way: while recording, these keystrokes
            // are input to the recorder, not to the window behind it.
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        heldModifiers = []
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotkeyModifiers(cgFlags: event.cgEvent?.flags ?? [])

        switch event.type {
        case .flagsChanged:
            // Modifiers only: commit when they're all released again, so
            // "hold Option, let go" records Option. Anything more than one
            // modifier can't be a bare-modifier hotkey — there's no single flag
            // to watch — so it waits for a key instead.
            if modifiers.isEmpty {
                if heldModifiers.isSingle {
                    commit(Hotkey(modifiers: heldModifiers))
                } else if !heldModifiers.isEmpty {
                    reject("Hold one modifier on its own, or add a key.")
                }
            } else {
                heldModifiers.formUnion(modifiers)
            }

        case .keyDown:
            let keyCode = event.keyCode
            // Esc backs out. Recording it would leave no way to cancel — and
            // Esc is already how you throw away a recording in progress.
            guard keyCode != KeyNames.escape else {
                stop()
                return
            }
            let candidate = Hotkey(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: KeyNames.label(
                    keyCode: keyCode,
                    characters: event.charactersIgnoringModifiers
                )
            )
            guard candidate.isUsable else {
                reject("Add a modifier — a bare key would type itself while you talk.")
                return
            }
            commit(candidate)

        default:
            break
        }
    }

    private func commit(_ new: Hotkey) {
        hotkey = new
        stop()
    }

    private func reject(_ why: String) {
        rejected = why
        heldModifiers = []
    }
}
