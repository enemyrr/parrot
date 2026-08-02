import AppKit
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var launchAgent = LaunchAgentState()

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Languages, startup, and where the log lives."
        ) {
            languagesCard
            startupCard
        }
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
