import AppKit
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var launchAgent = LaunchAgentState()

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "The key you hold to talk, and what happens when you let go."
        ) {
            hotkeyCard
            latchCard
            languagesCard
            startupCard
        }
    }

    // MARK: - Hotkey

    private var hotkeyCard: some View {
        SettingsCard(header: "Push to talk", footer: hotkeyFooter) {
            SettingsCustomRow(verticalPadding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(Hotkey.presets, id: \.self) { key in
                            HotkeyOption(
                                hotkey: key,
                                selected: store.settings.hotkey == key
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
                description: "Anything else — ⌃⌥Space, F13. Needs a modifier, "
                    + "or a function key.",
                wideControl: true
            ) {
                ShortcutRecorder(hotkey: $store.settings.hotkey)
            }
        }
    }

    /// Only says anything when there is something to say. A permanent caveat
    /// under a control that is working reads as a warning about nothing.
    private var hotkeyFooter: String? {
        guard !store.settings.hotkey.isBareModifier else { return nil }
        return "parrot watches the keyboard but never intercepts it, so the shortcut "
            + "still reaches whatever app is in front. Pick a combination nothing "
            + "else uses."
    }

    // MARK: - Hands-free

    private var latchCard: some View {
        SettingsCard(
            header: "Hands-free",
            footer: store.settings.latch.enabled
                ? nil
                : "With this off, a quick tap of the hotkey is treated as a very short recording."
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
                        format: { Self.durationLabel(Int($0)) }
                    )
                }
            }
        }
    }

    private static func durationLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60) min"
    }

    // MARK: - Languages

    private var languagesCard: some View {
        SettingsCard(
            header: "Languages",
            footer: languagesFooter
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                TokenListEditor(
                    tokens: $store.settings.languages,
                    placeholder: "Language code — en, sv, de…",
                    normalize: { $0.trimmingCharacters(in: .whitespaces).lowercased() },
                    validate: { LanguageSelection.supportedCodes.contains($0) }
                )
            }
        }
    }

    /// The setting reads like "only recognise these languages" and it is not
    /// that, so the pane says what it actually does rather than leaving the
    /// user to discover the difference mid-sentence.
    private var languagesFooter: String {
        let base = "The model always auto-detects across all 25 of its languages. "
            + "Listing yours only restricts the alphabet it may output, which "
            + "keeps stray Cyrillic or Han characters out of a Latin transcript."
        switch LanguageSelection.resolve(store.settings.languages) {
        case .conflicting(let scripts):
            return base + "\n⚠ Those span \(scripts.joined(separator: " + ")) alphabets, "
                + "so nothing can be filtered. List languages that share one."
        default:
            return base
        }
    }

    // MARK: - Startup

    private var startupCard: some View {
        SettingsCard(header: "Startup", footer: launchAgent.error) {
            SettingsRow(
                label: "Start parrot at login",
                description: "Runs in the background, in the menu bar. No dock icon."
            ) {
                Toggle("", isOn: Binding(
                    get: { launchAgent.installed },
                    set: { launchAgent.setInstalled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsRow(
                label: "Log file",
                description: ParrotPaths.stderrLog.path,
                wideControl: true
            ) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        ParrotPaths.stderrLog.path,
                        inFileViewerRootedAtPath: ParrotPaths.logDirectory.path
                    )
                }
            }
        }
    }
}

/// One selectable modifier, drawn as the key it is.
private struct HotkeyOption: View {
    let hotkey: Hotkey
    let selected: Bool
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
            .scaleEffect(hovering && !selected ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(hotkey.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A slider with its value spelled out beside it. Numeric fields for these
/// would invite values that make no sense — a 5 ms tap threshold, a 4-hour
/// safety stop — and the exact number is never what the user is choosing.
struct StepperSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            // Quantised in the binding rather than by `Slider(step:)`, which
            // draws a tick mark per step on macOS — 118 of them for the safety
            // stop, which reads as a hatched bar rather than a slider.
            Slider(value: quantised, in: range)
            Text(format(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private var quantised: Binding<Double> {
        Binding(
            get: { value },
            set: { raw in
                let snapped = (raw / step).rounded() * step
                value = min(range.upperBound, max(range.lowerBound, snapped))
            }
        )
    }
}

/// Reads and writes the launchd agent, and keeps the toggle honest about what
/// actually happened — a failed `bootstrap` has to show up as the switch
/// coming back rather than as silence.
@MainActor
private final class LaunchAgentState: ObservableObject {
    @Published private(set) var installed = LaunchAgent.isInstalled
    @Published private(set) var error: String?

    func setInstalled(_ wanted: Bool) {
        error = nil
        do {
            if wanted {
                let binary = try LaunchAgent.resolveBinary(override: nil)
                try LaunchAgent.install(binary: binary)
                LaunchAgent.bootout()
                let result = LaunchAgent.bootstrap()
                guard result.ok else {
                    try? LaunchAgent.uninstall()
                    throw LaunchFailure.launchctl(result.stderr)
                }
            } else {
                try LaunchAgent.uninstall()
            }
        } catch {
            self.error = "\(error)"
        }
        installed = LaunchAgent.isInstalled
    }

    enum LaunchFailure: Error, CustomStringConvertible {
        case launchctl(String)

        var description: String {
            switch self {
            case .launchctl(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "launchctl refused to load the agent\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }
}
