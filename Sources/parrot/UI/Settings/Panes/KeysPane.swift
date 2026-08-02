import SwiftUI

/// Both keys, and how they behave when you hold or tap them.
///
/// Split out of General once there were two of them: a pane that opens on
/// "which key starts which mode" is a different question from "does parrot
/// start at login", and the hotkeys are the thing people actually come here to
/// change.
struct KeysPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: "Keys",
            subtitle: "One key types what you say. The other answers for you."
        ) {
            dictationCard
            squawkCard
            latchCard
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

    private var latchCard: some View {
        SettingsCard(
            header: "Hands-free",
            footer: store.settings.latch.enabled
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

            if store.settings.latch.enabled {
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
        }
    }
}

/// One selectable modifier, drawn as the key it is.
struct HotkeyOption: View {
    let hotkey: Hotkey
    let selected: Bool
    var disabled = false
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Text(hotkey.modifiers.symbols)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .frame(height: 20)
                Text(hotkey.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 62, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : SettingsPalette.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : SettingsPalette.keycapBorder,
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
            .opacity(disabled ? 0.35 : 1)
            .scaleEffect(hovering && !selected && !disabled ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(hotkey.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
