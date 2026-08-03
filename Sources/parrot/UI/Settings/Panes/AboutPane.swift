import AppKit
import SwiftUI

struct AboutPane: View {
    @ObservedObject var store: SettingsStore

    @State private var confirmingReset = false
    @State private var confirmingDelete = false
    @State private var hasTranscripts = false
    @State private var flips = 0
    @State private var dialog: Dialog?
    /// Empty until `onAppear` fills them, and deliberately so: a `@State`
    /// default expression runs on every construction of the struct — which is
    /// every re-render of the settings window — and SwiftUI throws the value
    /// away. These cost a subprocess, a Keychain read per provider and a file
    /// stat, so they are done once on appearance instead.
    @State private var permissionSummary = ""
    @State private var accountSummary = ""

    /// How the menu bar's "finish setup" item, `parrot settings permissions`
    /// and `parrot settings accounts` land straight on the thing they name: the
    /// panes they used to open are sheets on this one now. A binding rather
    /// than a value because this pane is recreated on every visit — consuming
    /// it once is what keeps the sheet from reappearing on the way back to
    /// About.
    @Binding var openDialog: Dialog?

    init(store: SettingsStore, openDialog: Binding<Dialog?> = .constant(nil)) {
        self.store = store
        _openDialog = openDialog
    }

    /// The setup that used to be its own sidebar row each. Both are finished
    /// once and then never thought about, which is what a row-plus-sheet is for
    /// and a permanent page isn't.
    enum Dialog: String, Identifiable {
        case permissions, accounts
        var id: String { rawValue }
    }

    var body: some View {
        // No page title: the identity block below *is* the headline, the way
        // Home's is, and "About" set above a 52pt glyph and a wordmark captions
        // a room that has already introduced itself.
        SettingsPage {
            identity
            howToCard
            setupCard
            filesCard
            resetCard
        }
        .onAppear {
            hasTranscripts = Self.transcriptsExist
            refreshSummaries()
            if let requested = openDialog {
                openDialog = nil
                dialog = requested
            }
        }
        .sheet(item: $dialog, onDismiss: refreshSummaries) { which in
            switch which {
            case .permissions: PermissionsDialog(store: store) { dialog = nil }
            case .accounts: AccountsDialog(store: store) { dialog = nil }
            }
        }
        .confirmationDialog(
            "Reset every setting?",
            isPresented: $confirmingReset
        ) {
            Button("Reset", role: .destructive) {
                SettingsStore.shared.resetToDefaults()
            }
        } message: {
            Text("Hotkey, models, cleanup, style and dictionary all go back to "
                + "their defaults. Your transcripts, usage totals and API keys are "
                + "left alone.")
        }
        .confirmationDialog(
            "Delete every transcript?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { deleteTranscripts() }
        } message: {
            Text("\(ParrotPaths.historyFile.path) will be emptied. This can't be undone. "
                + "Your settings and usage totals are left alone.")
        }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            if let glyph = ParrotGlyph.image(size: 52) {
                Image(nsImage: glyph)
                    .foregroundStyle(.primary)
                    .rotation3DEffect(
                        .degrees(Double(flips) * 180),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.4
                    )
                    // Counting flips rather than toggling a bool: hovering out
                    // carries on in the same direction instead of rewinding.
                    .onHover { _ in flips += 1 }
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: flips)
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

    private var setupCard: some View {
        SettingsCard(header: "Setup") {
            SettingsDialogRow(
                label: "Permissions",
                value: permissionSummary,
                action: "Review"
            ) { dialog = .permissions }

            SettingsDialogRow(
                label: "Accounts",
                value: accountSummary,
                action: "Manage"
            ) { dialog = .accounts }
        }
    }

    private func refreshSummaries() {
        permissionSummary = Self.permissionSummary
        accountSummary = AccountsDialog.summary
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

    /// The two halves of "start over": the settings, and the data. Kept apart
    /// because each one is the thing the other promises not to touch.
    private var resetCard: some View {
        SettingsCard {
            SettingsRow(
                label: "Reset all settings",
                description: "Back to a fresh install, without touching your data.",
                wideControl: true
            ) {
                Button("Reset…", role: .destructive) { confirmingReset = true }
            }

            SettingsRow(
                label: "Delete all transcripts",
                description: "Permanently delete all local transcripts.",
                wideControl: true
            ) {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(!hasTranscripts)
            }
        }
    }

    private func deleteTranscripts() {
        try? TranscriptStore(settings: SettingsStore.shared.settings.history).clear()
        hasTranscripts = Self.transcriptsExist
    }

    /// Size rather than existence: clearing writes an empty file back, and a
    /// live Delete button over nothing is a button that does nothing.
    private static var transcriptsExist: Bool {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: ParrotPaths.historyFile.path)
        return (attributes?[.size] as? Int ?? 0) > 0
    }

    /// A single line for the row, so the sheet is worth opening only when it
    /// isn't "all good". Only the required checks count — the advisory ones are
    /// settings, not grants, and every other pane already reports on them.
    private static var permissionSummary: String {
        let missing = DoctorReport.run(settings: SettingsStore.shared.settings)
            .filter { DoctorReport.requiredKinds.contains($0.kind) && !$0.isOK }
            .map(\.name)
        guard !missing.isEmpty else { return "Microphone, Accessibility and the Fn key are all set." }
        let verb = missing.count == 1 ? "needs" : "need"
        return "\(missing.formatted(.list(type: .and))) still \(verb) attention."
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
            Button("Reveal in Finder") {
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
