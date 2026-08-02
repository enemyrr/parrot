import SwiftUI

/// The recording pill: whether it shows, what it looks like, how hard it
/// listens.
///
/// Sensitivity is impossible to judge from a number — it depends on your mic,
/// your room and how loudly you talk. So the pane can put the real pill on
/// screen and feed it your actual voice while you drag the slider, rather than
/// asking you to guess and then find out mid-sentence.
struct AppearancePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var context: SettingsContext

    private var overlay: OverlaySettings { store.settings.overlay }
    /// The daemon's flag, not the pane's — a dictation started mid-preview ends
    /// the preview, and so does a capture that fails to open.
    private var previewing: Bool { context.isPreviewing }

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "The pill that shows up while you're talking."
        ) {
            SettingsCard {
                SettingsRow(
                    label: "Show the recording pill",
                    description: "A small capsule at the bottom of the screen. "
                        + "It never takes focus and never swallows a click."
                ) {
                    Toggle("", isOn: $store.settings.overlay.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if overlay.enabled {
                sensitivityCard
            }
        }
        .onDisappear(perform: stopPreview)
    }

    private var sensitivityCard: some View {
        SettingsCard(
            header: "Sensitivity",
            footer: "Higher lowers the noise floor, so a quiet mic or a soft voice still "
                + "fills the meter. This only changes the picture — it has no effect on "
                + "what gets transcribed."
        ) {
            SettingsRow(label: "Meter response", description: sensitivityDescription) {
                StepperSlider(
                    value: Binding(
                        get: { overlay.sensitivity },
                        set: {
                            store.settings.overlay.sensitivity =
                                OverlaySettings.clampSensitivity($0)
                            syncPreview()
                        }
                    ),
                    range: 0.25...3,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )
            }

            SettingsCustomRow(verticalPadding: 12) {
                HStack(spacing: 10) {
                    Button {
                        previewing ? stopPreview() : startPreview()
                    } label: {
                        Label(
                            previewing ? "Stop preview" : "Preview with your microphone",
                            systemImage: previewing ? "stop.fill" : "mic.fill"
                        )
                    }
                    .disabled(!context.isLive)

                    Text(previewHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var sensitivityDescription: String {
        switch overlay.sensitivity {
        case ..<0.7: return "Only louder speech moves the meter."
        case 1.4...: return "Picks up quiet speech, and some room noise with it."
        default: return "The default. Tuned against a MacBook mic in a normal room."
        }
    }

    private var previewHint: String {
        if !context.isLive {
            return "Start parrot to preview against live audio."
        }
        return previewing
            ? "Talk — the pill is live at the bottom of the screen."
            : "Puts the real pill on screen and feeds it your microphone."
    }

    private func startPreview() {
        context.startOverlayPreview?(overlay.sensitivity)
    }

    private func stopPreview() {
        guard previewing else { return }
        context.endOverlayPreview?()
    }

    private func syncPreview() {
        guard previewing else { return }
        context.updateOverlayPreview?(overlay.sensitivity)
    }
}
