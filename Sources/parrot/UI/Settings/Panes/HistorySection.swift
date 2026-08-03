import AppKit
import SwiftUI

/// The transcripts, on the Home page. A section rather than a pane: "what did
/// I just dictate?" is the question the window gets opened for, so the answer
/// shouldn't be a sidebar click away.
///
/// The list is the whole surface. Sorting and deleting hide behind the
/// ellipsis, searching appears only once there is enough to search, and the
/// switches that govern storage live under Advanced — none of them are why
/// anyone scrolls down here.
struct HistorySection: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var data = HistoryData()

    @State private var confirmingClearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelSpacing) {
            header

            if store.settings.history.enabled {
                listCard
                footer
            } else {
                offCard
            }
        }
        .onAppear { data.reload(settings: store.settings) }
        // Turning history on above (or under Advanced) has to bring the list
        // to life without a pane switch in between.
        .onChange(of: store.settings.history.enabled) { _, _ in
            data.reload(settings: store.settings)
        }
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
    }

    // MARK: - Header

    /// The same label every other group on the page wears, with its controls
    /// parked at the end. It used to be 13pt semibold sentence case, which made
    /// the one section anybody scrolls to the one that didn't look like the
    /// others.
    private var header: some View {
        SettingsGroupLabel(title: "History") {
            // Menu first, search after — the reading order of the screenshot
            // this layout follows, and it keeps the field against the card edge.
            if store.settings.history.enabled {
                menu
            }

            if store.settings.history.enabled, data.totalEntries > HistoryData.searchThreshold {
                SearchField(text: $data.query, placeholder: "Search transcripts")
                    .frame(width: 200)
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Sort", selection: $data.newestFirst) {
                Text("Latest first").tag(true)
                Text("Earliest first").tag(false)
            }
            .pickerStyle(.inline)

            Divider()

            Button("Delete all…", role: .destructive) {
                confirmingClearHistory = true
            }
            .disabled(data.totalEntries == 0)
        } label: {
            // A bare glyph on its own glass disc, sized to sit flush with the
            // search capsule beside it. `ellipsis.circle` would draw a ring
            // inside the disc — a circle in a circle.
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .glassChip(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        // Plain, not borderless-button: that style paints its own bezel on
        // hover, which lands on top of the glass disc.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and manage history")
        .accessibilityLabel("History options")
    }

    // MARK: - List

    /// No card. The list is the entire section, so a fill and an edge fence it
    /// off from nothing — and they pushed every row 10pt to the right of the
    /// "History" label heading it. The hairlines already separate the rows.
    private var listCard: some View {
        DividedRowStack(dividerInset: SettingsMetrics.labelInset) {
            if data.items.isEmpty {
                SettingsCustomRow(verticalPadding: 18, horizontalPadding: SettingsMetrics.labelInset) {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ForEach(Array(data.items.enumerated()), id: \.element.id) { index, item in
                    switch item.kind {
                    case .day(let label):
                        DayHeaderRow(label: label, isFirst: index == 0)
                    case .entry(let entry):
                        TranscriptRow(entry: entry)
                    }
                }
            }

            if data.hasMore {
                SettingsCustomRow(verticalPadding: 8, horizontalPadding: SettingsMetrics.labelInset) {
                    Button("Show \(data.nextPageSize) more") { data.showMore() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var emptyMessage: String {
        data.query.isEmpty
            ? "Nothing dictated yet. Hold the key and talk."
            : "No transcripts match “\(data.query)”."
    }

    @ViewBuilder
    private var footer: some View {
        if data.totalEntries > 0 {
            let shown = "Showing \(data.shownCount) of \(data.matchCount.formatted())"
            SettingsGroupFooter(text: data.query.isEmpty
                ? "\(shown). Click a transcript to expand it. Everything stays on this Mac."
                : "\(shown) matching. Click a transcript to expand it.")
        }
    }

    /// History off isn't an error, but the section can't silently vanish
    /// either — that reads as a bug to anyone who remembers it being here.
    private var offCard: some View {
        SettingsCard {
            SettingsRow(
                label: "History is off",
                description: "Transcripts aren't being kept. Turn it on to see them here."
            ) {
                Toggle("", isOn: $store.settings.history.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
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
    /// The first heading already has the section label above it; 14pt on top of
    /// that reads as a hole rather than as the space between two days.
    var isFirst = false

    var body: some View {
        SettingsCustomRow(verticalPadding: 0, horizontalPadding: SettingsMetrics.labelInset) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.top, isFirst ? 2 : 14)
                .padding(.bottom, 4)
        }
        .plainCardRow()
    }
}

/// The transcript on one line, what it cost on the next.
///
/// The old single-line version spent a third of its width on a timestamp column
/// and an icon column, leaving the text — the only reason anyone opens this
/// list — clipped in the middle. Now the text gets the full width and the
/// details sit under it in a quieter register.
private struct TranscriptRow: View {
    let entry: TranscriptEntry

    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false

    private var showsRaw: Bool { entry.cleaned && entry.raw != entry.text }

    var body: some View {
        SettingsCustomRow(verticalPadding: 9, horizontalPadding: SettingsMetrics.labelInset) {
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
        // Rounded now that there is no card edge for a square highlight to run
        // into — on the bare page it would read as a band across the window.
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.chipCornerRadius, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.035) : .clear)
        )
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassChip(in: Capsule(style: .continuous))
    }
}

/// One line in the list: either a transcript or the day heading above a run of
/// them. Flattened into a single array so the card's divider logic sees them
/// as ordinary sibling rows.
private struct HistoryItem: Identifiable {
    enum Kind {
        case day(String)
        case entry(TranscriptEntry)
    }

    /// Derived from content, not position. Searching and flipping the sort
    /// rebuild this list with the same rows in different places; a positional
    /// id would hand a row's expanded state to whatever transcript landed
    /// there instead.
    let id: String
    let kind: Kind
}

/// Reads the on-disk store for the section. Kept out of the view so opening
/// the window doesn't re-read the file on every redraw.
@MainActor
private final class HistoryData: ObservableObject {
    static let pageSize = 12
    /// Below this, a search field is more chrome than help — the whole list is
    /// already on screen.
    static let searchThreshold = 8

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

    /// Flipping the sort keeps the query but starts paging over again — the
    /// first page of the other end, not page four of it.
    @Published var newestFirst = true {
        didSet {
            guard newestFirst != oldValue else { return }
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
        rebuild()
    }

    func showMore() {
        visible += Self.pageSize * 2
        rebuild()
    }

    func clearHistory(settings: Settings) {
        try? TranscriptStore(settings: settings.history).clear()
        reload(settings: settings)
    }

    // MARK: - Private

    private func rebuild() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        matches = needle.isEmpty
            ? entries
            : entries.filter {
                $0.text.lowercased().contains(needle) || $0.raw.lowercased().contains(needle)
            }
        if !newestFirst { matches.reverse() }
        matchCount = matches.count

        let shown = matches.prefix(visible)
        shownCount = shown.count
        hasMore = matchCount > shownCount

        // Headings come from walking the (already sorted) list and noticing the
        // label change, rather than a Dictionary group — that would lose the
        // order the whole section depends on.
        var built: [HistoryItem] = []
        var currentDay: String?
        for entry in shown {
            let label = Self.dayLabel(entry.at)
            if label != currentDay {
                built.append(HistoryItem(id: "day-\(label)", kind: .day(label)))
                currentDay = label
            }
            // `at` is stamped by Date() per transcript, so it identifies one.
            built.append(HistoryItem(
                id: "entry-\(entry.at.timeIntervalSince1970)",
                kind: .entry(entry)
            ))
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
}
