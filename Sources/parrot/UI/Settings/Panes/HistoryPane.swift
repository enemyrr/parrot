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
                        .disabled(data.totalEntries == 0)
                }
            }
        }
    }

    private var recentCard: some View {
        SettingsCard(header: "Recent", footer: recentFooter) {
            if data.totalEntries > HistoryPaneData.searchThreshold {
                SettingsCustomRow(verticalPadding: 8) {
                    SearchField(text: $data.query, placeholder: "Search transcripts")
                }
            }

            if data.items.isEmpty {
                SettingsCustomRow(verticalPadding: 18) {
                    Text(data.query.isEmpty ? "Nothing dictated yet." : "No transcripts match “\(data.query)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ForEach(data.items) { item in
                    switch item.kind {
                    case .day(let label):
                        DayHeaderRow(label: label)
                    case .entry(let entry):
                        TranscriptRow(entry: entry)
                    }
                }
            }

            if data.hasMore {
                SettingsCustomRow(verticalPadding: 8) {
                    Button("Show \(data.nextPageSize) more") { data.showMore() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var recentFooter: String? {
        guard data.totalEntries > 0 else { return nil }
        let shown = "Showing \(data.shownCount) of \(data.matchCount.formatted())"
        return data.query.isEmpty
            ? "\(shown). Click a transcript to expand it."
            : "\(shown) matching. Click a transcript to expand it."
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

/// A day's worth of transcripts starts here. Every stamp in the list below is
/// a bare time, so without this "09:12" from today and "09:12" from a fortnight
/// ago look identical — which is exactly how a list showing the wrong end of
/// the file managed to look plausible.
///
/// Just the words, unfenced: hairlines above and below turned a caption into
/// something that read like an empty row.
private struct DayHeaderRow: View {
    let label: String

    var body: some View {
        SettingsCustomRow(verticalPadding: 0) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
        .plainCardRow()
    }
}

/// The transcript on one line, what it cost on the next.
///
/// The old single-line version spent a third of its width on a timestamp column
/// and an icon column, leaving the text — the only reason anyone opens this
/// pane — clipped in the middle. Now the text gets the full width and the
/// details sit under it in a quieter register.
private struct TranscriptRow: View {
    let entry: TranscriptEntry

    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false

    private var showsRaw: Bool { entry.cleaned && entry.raw != entry.text }

    var body: some View {
        SettingsCustomRow(verticalPadding: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.text)
                        .font(.system(size: 12.5))
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    copyButton
                        .padding(.top, 1)
                }

                metaLine

                if expanded, showsRaw {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BEFORE CLEANUP")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                        Text(entry.raw)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            }
        }
        .background(hovering ? Color.primary.opacity(0.035) : .clear)
    }

    /// Copy rather than re-inject: focus has long since gone back to whatever
    /// was underneath, and typing into it uninvited is the worse surprise.
    /// Its own button now — clicking the row expands, and one gesture can't
    /// sensibly mean both.
    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : .secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(copied || hovering ? 1 : 0)
        .help("Copy this transcript")
        .accessibilityLabel("Copy transcript")
    }

    private var metaLine: some View {
        HStack(spacing: 5) {
            Text(DateFormatter.menuStamp.string(from: entry.at))
                .monospacedDigit()
            separator
            Text(Stats.duration(entry.seconds))
            separator
            Text("\(StatsStore.wordCount(entry.text)) words")

            if entry.latched {
                separator
                Label("hands-free", systemImage: "lock.fill")
                    .labelStyle(.iconOnly)
                    .help("Recorded hands-free")
            }
            if entry.cleaned {
                separator
                Label("cleaned up", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
                    .help(showsRaw ? "Cleaned up — click to see the raw text" : "Cleaned up")
            }

            Spacer(minLength: 8)

            if expanded {
                Text(Self.modelLabel(entry.model))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private static func modelLabel(_ id: String) -> String {
        ModelRegistry.find(id)?.displayName ?? id
    }

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

/// A plain field with a magnifier and a clear button. `.searchable` belongs to
/// a navigation container this window doesn't have, and a bare `TextField`
/// gives no hint that typing filters the list under it.
private struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SettingsPalette.chipFill)
        )
    }
}

/// One line in the Recent list: either a transcript or the day heading above a
/// run of them. Flattened into a single array so the card's divider logic sees
/// them as ordinary sibling rows.
private struct HistoryItem: Identifiable {
    enum Kind {
        case day(String)
        case entry(TranscriptEntry)
    }

    let id: Int
    let kind: Kind
}

/// Reads the two on-disk stores for the pane. Kept out of the view so opening
/// the window doesn't re-read the files on every redraw.
@MainActor
private final class HistoryPaneData: ObservableObject {
    static let pageSize = 12
    /// Below this, a search field is more chrome than help — the whole list is
    /// already on screen.
    static let searchThreshold = 8

    @Published private(set) var summary: StatsSummary?
    @Published private(set) var totalEntries = 0
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var matchCount = 0
    @Published private(set) var shownCount = 0
    @Published private(set) var hasMore = false

    /// Typing filters the list, so a new query starts from the top page again.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            visible = Self.pageSize
            rebuild()
        }
    }

    /// Newest first, as `TranscriptStore.all()` returns them.
    private var entries: [TranscriptEntry] = []
    private var matches: [TranscriptEntry] = []
    private var visible = pageSize

    var nextPageSize: Int { min(Self.pageSize * 2, matchCount - shownCount) }

    func reload(settings: Settings) {
        let store = TranscriptStore(settings: settings.history)
        // `all()` is already newest first — take from the front, don't re-sort.
        entries = store.all()
        totalEntries = entries.count
        summary = StatsStore(settings: settings.stats).summary(typingWpm: settings.stats.typingWpm)
        rebuild()
    }

    func showMore() {
        visible += Self.pageSize * 2
        rebuild()
    }

    // MARK: - Private

    private func rebuild() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        matches = needle.isEmpty
            ? entries
            : entries.filter {
                $0.text.lowercased().contains(needle) || $0.raw.lowercased().contains(needle)
            }
        matchCount = matches.count

        let shown = matches.prefix(visible)
        shownCount = shown.count
        hasMore = matchCount > shownCount

        // Headings come from walking the (already sorted) list and noticing the
        // label change, rather than a Dictionary group — that would lose the
        // newest-first order the whole pane depends on.
        var built: [HistoryItem] = []
        var currentDay: String?
        for entry in shown {
            let label = Self.dayLabel(entry.at)
            if label != currentDay {
                built.append(HistoryItem(id: built.count, kind: .day(label)))
                currentDay = label
            }
            built.append(HistoryItem(id: built.count, kind: .entry(entry)))
        }
        items = built
    }

    private static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
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
