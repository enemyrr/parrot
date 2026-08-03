import SwiftUI

/// Phrases you say on purpose, and the text they turn into.
///
/// A tab of its own inside Dictionary rather than a third card beside the
/// corrections: the dictionary repairs words you didn't mean to get wrong, this
/// fires on words you chose deliberately. Stacked in one scroll they blur
/// together — and a shortcut's expansion is a paragraph, which never sat well
/// under a two-column correction table.
struct ShortcutsSection: View {
    @ObservedObject var store: SettingsStore

    /// Only one open at a time: expanded rows are tall, and a list of them
    /// scrolls past the point where you can compare any two.
    @State private var expanded: UUID?

    var body: some View {
        shortcutsCard
    }

    private var shortcutsCard: some View {
        SettingsCard(
            header: "Your shortcuts",
            footer: "Matched case-insensitively on whole words, wherever the phrase lands in "
                + "what you said. Expansions are typed exactly as written — cleanup never "
                + "sees them, so an address or a prompt comes out the way you wrote it."
        ) {
            if store.settings.shortcuts.isEmpty {
                emptyRow
            } else {
                ForEach($store.settings.shortcuts) { $shortcut in
                    ShortcutRow(
                        shortcut: $shortcut,
                        isExpanded: expanded == shortcut.id,
                        toggle: { toggle(shortcut.id) },
                        delete: { remove(shortcut.id) }
                    )
                }
            }

            SettingsCustomRow(verticalPadding: 8) {
                Button(action: add) {
                    Label("Add a shortcut", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }

    private var emptyRow: some View {
        SettingsCustomRow(verticalPadding: 18) {
            VStack(spacing: 6) {
                Text("No shortcuts yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Say “my email shortcut”, get andreas@example.com.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func add() {
        let shortcut = TextShortcut()
        store.settings.shortcuts.append(shortcut)
        expanded = shortcut.id
    }

    private func toggle(_ id: UUID) {
        expanded = expanded == id ? nil : id
    }

    private func remove(_ id: UUID) {
        store.settings.shortcuts.removeAll { $0.id == id }
        if expanded == id { expanded = nil }
    }
}

/// One shortcut, collapsed to a line you can scan or opened to two fields.
///
/// Collapsed is the resting state on purpose: a shortcut is something you set
/// up once and then only ever read back — "what did I call that again?" — and a
/// list of open text editors answers that question worse than a list of lines.
private struct ShortcutRow: View {
    @Binding var shortcut: TextShortcut
    let isExpanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        SettingsCustomRow(verticalPadding: isExpanded ? 12 : 8) {
            VStack(alignment: .leading, spacing: 12) {
                summary
                if isExpanded { fields }
            }
        }
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(trigger)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(shortcut.trigger.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Text(expansionPreview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: delete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isExpanded ? 1 : 0)
            .help("Remove this shortcut")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("YOU SAY") {
                CommittedText(text: $shortcut.trigger) { draft in
                    TextField("my email shortcut", text: draft)
                        .textFieldStyle(.roundedBorder)
                }
            }

            field("PARROT TYPES") {
                CommittedText(text: $shortcut.expansion) { draft in
                    PromptEditor(
                        text: draft,
                        placeholder: "andreas@example.com",
                        minHeight: 76
                    )
                }
            }
        }
        // Lines the fields up under the trigger rather than the chevron.
        .padding(.leading, 18)
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private var trigger: String {
        shortcut.trigger.isEmpty ? "New shortcut" : shortcut.trigger
    }

    /// One line, whatever the expansion is. A multi-line signature collapsed to
    /// its first line with the rest implied reads better than a row that grows
    /// to eight lines tall in a list.
    private var expansionPreview: String {
        let trimmed = shortcut.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let first = trimmed.split(separator: "\n", maxSplits: 1)[0]
        return first.count < trimmed.count ? "\(first)…" : String(first)
    }
}
