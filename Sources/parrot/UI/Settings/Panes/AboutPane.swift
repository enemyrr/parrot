import AppKit
import SwiftUI

struct AboutPane: View {
    @State private var confirmingReset = false

    var body: some View {
        SettingsPage(title: "About") {
            identity
            howToCard
            filesCard
            resetCard
        }
        .confirmationDialog(
            "Reset every setting?",
            isPresented: $confirmingReset
        ) {
            Button("Reset", role: .destructive) {
                SettingsStore.shared.resetToDefaults()
            }
        } message: {
            Text("Hotkey, models, cleanup, dictionary and appearance all go back to "
                + "their defaults. Your transcripts, usage totals and API keys are "
                + "left alone.")
        }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            if let glyph = ParrotGlyph.image(size: 52) {
                Image(nsImage: glyph)
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("parrot")
                    .font(.system(size: 26, weight: .semibold))
                Text("Version \(Self.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("On-device dictation. Hold a key, talk, and it types.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private var howToCard: some View {
        SettingsCard(header: "How it works") {
            SettingsCustomRow(verticalPadding: 14) {
                VStack(alignment: .leading, spacing: 11) {
                    Step(
                        number: 1,
                        text: "Click into any text field — Messages, an address bar, a Slack thread."
                    )
                    Step(
                        number: 2,
                        text: "Hold the hotkey and talk. Or double-tap it for hands-free."
                    )
                    Step(
                        number: 3,
                        text: "Let go. The transcript types itself in at the cursor. "
                            + "Escape throws a recording away."
                    )
                }
            }
        }
    }

    private var filesCard: some View {
        SettingsCard(
            header: "On disk",
            footer: "Settings themselves live in macOS preferences now — there is no "
                + "config file to edit."
        ) {
            FileRow(label: "Transcripts", path: ParrotPaths.historyFile.path)
            FileRow(label: "Usage totals", path: ParrotPaths.statsFile.path)
            FileRow(label: "Logs", path: ParrotPaths.stderrLog.path)
            FileRow(label: "Models", path: ModelRegistry.shared[0].cacheDirectory.path)
        }
    }

    private var resetCard: some View {
        SettingsCard {
            SettingsRow(
                label: "Reset all settings",
                description: "Back to a fresh install, without touching your data.",
                wideControl: true
            ) {
                Button("Reset…", role: .destructive) { confirmingReset = true }
            }
        }
    }

    /// The bundled `.app` carries a real version; a bare binary on `$PATH` has
    /// no `Info.plist` to read one from, and claiming "1.0" there would be a
    /// guess dressed up as a fact.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev build"
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FileRow: View {
    let label: String
    let path: String

    var body: some View {
        SettingsRow(label: label, description: path, wideControl: true) {
            Button("Reveal") {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.selectFile(
                    path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            }
            .disabled(!FileManager.default.fileExists(atPath: path))
        }
    }
}
