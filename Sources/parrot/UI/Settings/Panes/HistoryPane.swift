import AppKit
import SwiftUI

/// What parrot keeps: the transcripts themselves, and the counts derived from
/// them. Two separate switches because they are two separate promises — stats
/// hold no text, so they can stay on with history off.
struct HistoryPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var data = HistoryPaneData()

    @State private var confirmingClearHistory = false
    @State private var confirmingResetStats = false

    var body: some View {
        SettingsPage(
            title: "History",
            subtitle: "Everything here stays on this Mac, in plain files you can read."
        ) {
            historyCard
            if store.settings.history.enabled {
                recentCard
            }
            statsCard
        }
        .onAppear { data.reload(settings: store.settings) }
        .confirmationDialog(
            "Delete every transcript?",
            isPresented: $confirmingClearHistory
        ) {
            Button("Delete", role: .destructive) {
                data.clearHistory(settings: store.settings)
            }
        } message: {
            Text("\(ParrotPaths.historyFile.path) will be emptied. This can't be undone. "
                + "Usage totals are kept in a separate file and aren't affected.")
        }
        .confirmationDialog(
            "Reset usage totals?",
            isPresented: $confirmingResetStats
        ) {
            Button("Reset", role: .destructive) {
                data.resetStats(settings: store.settings)
            }
        } message: {
            Text("Your lifetime word count and time saved go back to zero.")
        }
    }

    // MARK: - History

    private var historyCard: some View {
        SettingsCard(
            header: "Transcripts",
            footer: "Stored as JSON lines at \(ParrotPaths.historyFile.path)."
        ) {
            SettingsRow(
                label: "Keep a history",
                description: "Every transcript, with the raw text before cleanup."
            ) {
                Toggle("", isOn: $store.settings.history.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.settings.history.enabled {
                SettingsRow(
                    label: "Keep at most",
                    description: "Older entries are pruned at startup."
                ) {
                    StepperSlider(
                        value: Binding(
                            get: { Double(store.settings.history.maxEntries) },
                            set: { store.settings.history.maxEntries = Int($0) }
                        ),
                        range: 100...20000,
                        step: 100,
                        format: { "\(Int($0).formatted())" }
                    )
                }
            }

            SettingsRow(label: "Stored file", description: data.historySummary, wideControl: true) {
                HStack(spacing: 8) {
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(
                            ParrotPaths.historyFile.path,
                            inFileViewerRootedAtPath: ParrotPaths.dataDirectory.path
                        )
                    }
                    Button("Clear…") { confirmingClearHistory = true }
                        .disabled(data.recent.isEmpty)
                }
            }
        }
    }

    private var recentCard: some View {
        SettingsCard(header: "Recent", footer: data.recent.isEmpty ? nil : "Click a line to copy it.") {
            if data.recent.isEmpty {
                SettingsCustomRow(verticalPadding: 16) {
                    Text("Nothing dictated yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ForEach(Array(data.recent.enumerated()), id: \.offset) { _, entry in
                    TranscriptRow(entry: entry)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsCard: some View {
        SettingsCard(
            header: "Usage",
            footer: "Counts only — never the text you dictated. Kept in its own file, "
                + "so clearing history doesn't reset them."
        ) {
            SettingsRow(label: "Count what I dictate", description: nil) {
                Toggle("", isOn: $store.settings.stats.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.settings.stats.enabled {
                SettingsRow(
                    label: "Compare against typing at",
                    description: "Used only to work out “time saved”. 40 wpm is "
                        + "composing-original-text speed, well below a typing test."
                ) {
                    StepperSlider(
                        value: Binding(
                            get: { store.settings.stats.typingWpm },
                            set: { store.settings.stats.typingWpm = StatsSettings.clampWpm($0) }
                        ),
                        range: 10...200,
                        step: 5,
                        format: { "\(Int($0)) wpm" }
                    )
                }

                if let summary = data.summary, summary.sessions > 0 {
                    SettingsCustomRow(verticalPadding: 14) {
                        HStack(spacing: 0) {
                            StatTile(value: summary.words.formatted(), label: "words")
                            StatTile(
                                value: Stats.duration(summary.secondsSaved),
                                label: "saved"
                            )
                            StatTile(
                                value: "\(Int(summary.averageWpm.rounded()))",
                                label: "wpm speaking"
                            )
                            StatTile(
                                value: summary.sessions.formatted(),
                                label: summary.sessions == 1 ? "recording" : "recordings"
                            )
                        }
                    }
                }

                SettingsRow(label: "Totals", description: data.statsSummary, wideControl: true) {
                    Button("Reset…") { confirmingResetStats = true }
                        .disabled((data.summary?.sessions ?? 0) == 0)
                }
            }
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        SettingsCustomRow(verticalPadding: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(DateFormatter.menuStamp.string(from: entry.at))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .leading)
                    .padding(.top, 1)

                Text(entry.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    if entry.latched {
                        Image(systemName: "lock.fill").help("Hands-free")
                    }
                    if entry.cleaned {
                        Image(systemName: "sparkles").help("Cleaned up")
                    }
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .opacity(copied || hovering ? 1 : 0)
                }
                .font(.system(size: 9))
                .foregroundStyle(copied ? Color.green : .secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 2)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: copy)
        }
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
    }

    /// Copy rather than re-inject: focus has long since gone back to whatever
    /// was underneath, and typing into it uninvited is the worse surprise.
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

/// Reads the two on-disk stores for the pane. Kept out of the view so opening
/// the window doesn't re-read the files on every redraw.
@MainActor
private final class HistoryPaneData: ObservableObject {
    private static let recentCount = 12

    @Published private(set) var recent: [TranscriptEntry] = []
    @Published private(set) var summary: StatsSummary?
    @Published private(set) var totalEntries = 0

    func reload(settings: Settings) {
        let store = TranscriptStore(settings: settings.history)
        // `all()` is already newest first — take from the front, don't re-sort.
        let all = store.all()
        totalEntries = all.count
        recent = Array(all.prefix(Self.recentCount))
        summary = StatsStore(settings: settings.stats).summary(typingWpm: settings.stats.typingWpm)
    }

    var historySummary: String {
        totalEntries == 0
            ? "Empty"
            : "\(totalEntries.formatted()) \(totalEntries == 1 ? "transcript" : "transcripts")"
    }

    var statsSummary: String {
        guard let summary, summary.sessions > 0 else { return "Nothing counted yet" }
        let days = summary.daysUsed
        return "Across \(days) \(days == 1 ? "day" : "days")"
    }

    func clearHistory(settings: Settings) {
        try? TranscriptStore(settings: settings.history).clear()
        reload(settings: settings)
    }

    func resetStats(settings: Settings) {
        try? StatsStore(settings: settings.stats).reset()
        reload(settings: settings)
    }
}
