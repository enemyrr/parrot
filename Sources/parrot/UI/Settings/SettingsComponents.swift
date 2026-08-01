import SwiftUI

/// The building blocks every pane is made of.
///
/// One vocabulary — page, card, row — rather than each pane inventing its own
/// spacing. It's what keeps eight unrelated screens reading as one window.
enum SettingsMetrics {
    static let pageHorizontalPadding: CGFloat = 26
    static let pageVerticalPadding: CGFloat = 22
    static let cardCornerRadius: CGFloat = 10
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
    /// Rows line their controls up on a shared column so labels of different
    /// lengths don't leave the controls ragged.
    static let controlColumnWidth: CGFloat = 200
    static let sectionSpacing: CGFloat = 22
}

// MARK: - Page

/// A pane's outer frame: a title, an optional one-line explanation of what the
/// pane is for, then scrolling content.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageHorizontalPadding)
            .padding(.vertical, SettingsMetrics.pageVerticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Without this, a pane whose content overflows can open scrolled to
        // whatever SwiftUI decided to focus — History opened halfway down its
        // own transcript list, with its title off screen.
        .defaultScrollAnchor(.top)
        .background(SettingsPalette.pageBackground)
    }
}

// MARK: - Card

/// A group of rows on one raised surface, with hairlines between them.
/// Optionally headed by a label, the way System Settings groups related knobs.
struct SettingsCard<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }

            _VariadicView.Tree(DividedRows()) { content }
                .background(SettingsPalette.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(SettingsPalette.cardBorder, lineWidth: 0.5)
                )

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
            }
        }
    }
}

/// Stacks a card's rows and puts a hairline between each pair — but not after
/// the last one, which is the whole reason this needs the variadic view: a
/// plain `VStack` can't tell which of its children is last.
private struct DividedRows: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let rows = Array(children)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, child in
                child
                // Both sides get a say: a caption row shouldn't be boxed in by
                // the row above it either.
                if index < rows.count - 1,
                   !child[PlainRowTrait.self],
                   !rows[index + 1][PlainRowTrait.self] {
                    Divider()
                        .padding(.leading, SettingsMetrics.rowHorizontalPadding)
                }
            }
        }
    }
}

private struct PlainRowTrait: _ViewTraitKey {
    static var defaultValue: Bool { false }
}

extension View {
    /// Marks a row that shouldn't be fenced off by hairlines — a caption
    /// heading a run of rows rather than a row in its own right.
    func plainCardRow() -> some View {
        _trait(PlainRowTrait.self, true)
    }
}

// MARK: - Row

/// Label (and optional explanation) on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    var description: String?
    /// Let the control size itself instead of pinning it to the shared column —
    /// for a full-width text field or a row of buttons.
    var wideControl = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(
                    width: wideControl ? nil : SettingsMetrics.controlColumnWidth,
                    alignment: .trailing
                )
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(minHeight: 38)
    }
}

/// A row that is entirely custom content — a model card, a permission line, a
/// table. Keeps the card's padding and divider behaviour without imposing the
/// label/control split.
struct SettingsCustomRow<Content: View>: View {
    var verticalPadding: CGFloat = SettingsMetrics.rowVerticalPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
            .padding(.vertical, verticalPadding)
    }
}

// MARK: - Pieces

/// Free-text that reaches the store when the user is done with it, rather than
/// on every keystroke.
///
/// A settings write persists to disk *and* makes the daemon rebuild whatever
/// the changed section names. For a toggle that is exactly right; for a
/// paragraph of prompt it means a hundred rebuilds, a hundred keychain reads
/// and two hundred log lines for one edit. So the draft is local until focus
/// leaves.
struct CommittedText<Field: View>: View {
    @Binding var text: String
    /// Builds the control around the local draft binding.
    @ViewBuilder var field: (Binding<String>) -> Field

    @State private var draft: String
    @FocusState private var focused: Bool

    init(text: Binding<String>, @ViewBuilder field: @escaping (Binding<String>) -> Field) {
        self._text = text
        self.field = field
        self._draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        field($draft)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            // Someone else changed it — "restore defaults", or the other pane
            // writing the same section. An untouched field has to follow.
            .onChange(of: text) { _, new in
                guard !focused else { return }
                draft = new
            }
    }

    private func commit() {
        guard draft != text else { return }
        text = draft
    }
}

/// A frozen scrap of waveform, for the "this is what you said" chips. Static on
/// purpose — it stands for speech, it isn't reporting on any.
struct MiniWaveform: View {
    var tint: Color = .secondary
    var height: CGFloat = 11

    private static let bars: [CGFloat] = [
        0.35, 0.7, 1.0, 0.5, 0.85, 0.4, 0.65, 0.95, 0.55, 0.3, 0.6, 0.25,
    ]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint)
                    .frame(width: 1.5, height: max(1.5, level * height))
            }
        }
        .frame(height: height)
    }
}

/// Pass / warn / fail, as a dot and a word. Colour alone would be the only
/// signal for someone who can't distinguish green from amber, hence the icon
/// shape changing too.
struct StatusIndicator: View {
    let status: CheckStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private var accessibilityText: String {
        switch status {
        case .ok: return "OK"
        case .warn(let m): return "Warning: \(m)"
        case .fail(let m): return "Failed: \(m)"
        }
    }
}

/// An editable list of short strings — vocabulary terms, language codes.
/// A table would be heavy for one column; this is a wrapping row of chips with
/// a field to add to it.
struct TokenListEditor: View {
    @Binding var tokens: [String]
    var placeholder: String
    /// Normalises what the user typed (trim, lowercase for language codes).
    var normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
    var validate: (String) -> Bool = { !$0.isEmpty }

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tokens.isEmpty {
                // Keyed and removed by value, not by index: `commit` already
                // rejects duplicates, and a captured index outlives the array
                // it indexed — two removals in one frame and the second one
                // traps.
                FlowLayout(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        Chip(text: token) { tokens.removeAll { $0 == token } }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(!validate(normalize(draft)))
            }
        }
    }

    private func commit() {
        let value = normalize(draft)
        guard validate(value), !tokens.contains(value) else {
            draft = ""
            return
        }
        tokens.append(value)
        draft = ""
    }
}

private struct Chip: View {
    let text: String
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(SettingsPalette.chipFill)
        )
        .onHover { hovering = $0 }
    }
}

/// Left-to-right wrapping layout. Chips need to wrap and `HStack` won't; the
/// `Layout` protocol makes this ~30 lines rather than a hand-rolled measuring pass.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > width {
                current.width = x - spacing
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty {
            current.width = x - spacing
            rows.append(current)
        }
        return rows
    }
}

// MARK: - Palette

/// Named surfaces rather than raw `NSColor`s scattered through the panes, so
/// light and dark stay in step and there is one place to retune them.
enum SettingsPalette {
    static var pageBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var cardBorder: Color {
        Color(nsColor: .separatorColor).opacity(0.7)
    }

    static var keycapFill: Color {
        Color(nsColor: .controlColor)
    }

    static var keycapBorder: Color {
        Color(nsColor: .separatorColor)
    }

    static var chipFill: Color {
        Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    }
}
