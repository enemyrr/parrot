import SwiftUI

/// Both keys, and how they behave when you hold or tap them.
///
/// Was a sidebar pane of its own. It is the thing people come here to change
/// once and then never look at again, which is exactly the shape of a dialog
/// rather than of a permanent row in the sidebar.
struct ShortcutsDialog: View {
    @ObservedObject var store: SettingsStore
    let dismiss: () -> Void

    var body: some View {
        SettingsDialog(
            title: "Shortcuts",
            subtitle: "One key types what you say. The other answers for you.",
            dismiss: dismiss
        ) {
            dictationCard
            squawkCard
            handsFreeCard
            AdvancedDisclosure { timingCard }
        }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        SettingsCard(header: "Dictation", footer: hotkeyFooter) {
            SettingsCustomRow(verticalPadding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(Hotkey.presets, id: \.self) { key in
                            HotkeyOption(
                                hotkey: key,
                                selected: store.settings.hotkey == key,
                                disabled: squawkEnabled && key == store.settings.squawk.hotkey
                            ) {
                                store.settings.hotkey = key
                            }
                        }
                    }
                    Text("Hold \(store.settings.hotkey.displayName) and talk. Release to "
                        + "transcribe, press Escape to throw the recording away.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsRow(
                label: "Custom shortcut",
                description: "Anything else — ⌃⌥Space, F13. Needs a modifier, or a function key.",
                wideControl: true
            ) {
                ShortcutRecorder(hotkey: $store.settings.hotkey)
            }
        }
    }

    private var hotkeyFooter: String? {
        guard !store.settings.hotkey.isBareModifier else { return nil }
        return "parrot watches the keyboard but never intercepts it, so the shortcut "
            + "still reaches whatever app is in front. Pick a combination nothing "
            + "else uses."
    }

    // MARK: - Squawk

    private var squawkEnabled: Bool { store.settings.squawk.enabled }

    private var squawkCard: some View {
        SettingsCard(header: "Squawk", footer: squawkFooter) {
            SettingsRow(
                label: "Talk to it instead of through it",
                description: "What you say is an instruction, not the text. It reads the app "
                    + "you're in and writes the answer at the cursor."
            ) {
                Toggle("", isOn: $store.settings.squawk.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if squawkEnabled {
                SettingsCustomRow(verticalPadding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            ForEach(Hotkey.presets, id: \.self) { key in
                                HotkeyOption(
                                    hotkey: key,
                                    selected: store.settings.squawk.hotkey == key,
                                    disabled: key == store.settings.hotkey
                                ) {
                                    store.settings.squawk.hotkey = key
                                }
                            }
                        }
                        Text("Hold \(store.settings.squawk.hotkey.displayName) and say what you "
                            + "want — “answer this, ten o'clock works” or “rewrite this, friendlier”.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRow(
                    label: "Custom shortcut",
                    description: "Anything else — ⌃⌥Space, F13.",
                    wideControl: true
                ) {
                    ShortcutRecorder(hotkey: $store.settings.squawk.hotkey)
                }
            }
        }
    }

    /// The one state that silently does nothing: two hotkeys that are the same
    /// key. The daemon drops the squawk binding rather than guess, and this is
    /// the only place that can say so.
    private var squawkFooter: String? {
        let squawk = store.settings.squawk
        guard squawk.enabled else {
            return "Off means the second key isn't registered and nothing reads the screen."
        }
        guard squawk.isUsable(alongside: store.settings.hotkey) else {
            return "⚠ \(squawk.hotkey.displayLabel) is already the dictation key, so squawk "
                + "is switched off until you pick another."
        }
        if squawk.hotkey.isBareModifier {
            return "A key you press with something else — ⌃C, ⌘⌃F — cancels the recording "
                + "instead of starting one, so ordinary shortcuts still work."
        }
        return nil
    }

    // MARK: - Hands-free

    private var latchEnabled: Bool { store.settings.latch.enabled }

    private var handsFreeCard: some View {
        SettingsCard(
            header: "Hands-free",
            footer: latchEnabled
                ? "Applies to both keys."
                : "With this off, a quick tap of either key is treated as a very short recording."
        ) {
            SettingsRow(
                label: "Double-tap to latch",
                description: "Tap twice to keep recording without holding. Tap once more to stop."
            ) {
                Toggle("", isOn: $store.settings.latch.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    /// Three numbers nobody needs the first week, and one of them is measured in
    /// milliseconds. They stay behind the disclosure — greyed rather than hidden
    /// when latching is off, so it is obvious what switching it on would buy.
    private var timingCard: some View {
        SettingsCard(
            header: "Hands-free timing",
            footer: latchEnabled ? nil : "Switch on double-tap to latch to use these."
        ) {
            SettingsRow(
                label: "Tap threshold",
                description: "A hold shorter than this counts as a tap, not speech."
            ) {
                StepperSlider(
                    value: Binding(
                        get: { Double(store.settings.latch.tapMs) },
                        set: { store.settings.latch.tapMs = Int($0) }
                    ),
                    range: 120...600,
                    step: 10,
                    format: { "\(Int($0)) ms" }
                )
            }

            SettingsRow(
                label: "Double-tap window",
                description: "How long the second tap has to land."
            ) {
                StepperSlider(
                    value: Binding(
                        get: { Double(store.settings.latch.windowMs) },
                        set: { store.settings.latch.windowMs = Int($0) }
                    ),
                    range: 150...600,
                    step: 10,
                    format: { "\(Int($0)) ms" }
                )
            }

            SettingsRow(
                label: "Safety stop",
                description: "A forgotten hands-free recording stops itself after this."
            ) {
                StepperSlider(
                    value: Binding(
                        get: { Double(store.settings.latch.maxSeconds) },
                        set: { store.settings.latch.maxSeconds = Int($0) }
                    ),
                    range: 30...900,
                    step: 30,
                    format: { $0 < 60 ? "\(Int($0))s" : "\(Int($0) / 60) min" }
                )
            }
        }
        .disabled(!latchEnabled)
        .opacity(latchEnabled ? 1 : 0.55)
    }
}
