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
                styleCard
                sensitivityCard
            }
        }
        .onDisappear(perform: stopPreview)
    }

    private var styleCard: some View {
        SettingsCard(header: "Visualiser") {
            SettingsCustomRow(verticalPadding: 12) {
                HStack(spacing: 10) {
                    ForEach(OverlayStyle.allCases) { style in
                        StyleOption(style: style, selected: overlay.style == style) {
                            store.settings.overlay.style = style
                            syncPreview()
                        }
                    }
                }
            }
        }
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
        context.startOverlayPreview?(overlay.style, overlay.sensitivity)
    }

    private func stopPreview() {
        guard previewing else { return }
        context.endOverlayPreview?()
    }

    private func syncPreview() {
        guard previewing else { return }
        context.updateOverlayPreview?(overlay.style, overlay.sensitivity)
    }
}

/// A style option that draws the thing it names, at pill scale.
private struct StyleOption: View {
    let style: OverlayStyle
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 9) {
                ZStack {
                    Capsule()
                        .fill(Color.black.opacity(0.82))
                        .frame(height: 34)
                    sample
                }
                .frame(maxWidth: .infinity)

                Text(style.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : SettingsPalette.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : SettingsPalette.keycapBorder,
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selected)
    }

    /// A frozen frame of each visualiser rather than a live one: two animating
    /// swatches side by side compete for attention, and the choice here is
    /// between shapes, not between motions.
    @ViewBuilder
    private var sample: some View {
        switch style {
        case .bars:
            HStack(spacing: 2) {
                ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(OverlayPill.accent)
                        .frame(width: 2, height: max(2, height * 18))
                }
            }
        case .line:
            WaveSample()
                .stroke(OverlayPill.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 54, height: 18)
        }
    }

    private static let barHeights: [CGFloat] = [
        0.15, 0.3, 0.55, 0.85, 0.6, 0.35, 0.7, 1.0, 0.75, 0.4, 0.55, 0.3, 0.2, 0.12,
    ]
}

private struct WaveSample: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        for x in stride(from: 0.0, through: rect.width, by: 1) {
            let u = x / rect.width
            let taper = pow(sin(u * .pi), 0.8)
            let y = mid + sin(u * .pi * 2 * 1.6) * (rect.height / 2 - 1) * taper
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
