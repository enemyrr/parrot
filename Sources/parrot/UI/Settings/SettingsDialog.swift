import SwiftUI

/// A settings sheet: title, the same cards every pane is made of, one Done
/// button.
///
/// The alternative was a sidebar row per knob, which is how the window grew a
/// "Keys" pane you visit twice a year. A row that states its current value and
/// opens on demand keeps the answer on the main page and the machinery out of
/// the way.
struct SettingsDialog<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 520
    let dismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Tall enough for the longest dialog, short enough that a sheet
            // never outgrows the window it is attached to.
            .frame(maxHeight: 460)

            Divider()
            footer
        }
        .frame(width: width)
        .background(SettingsPalette.pageBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Everything that is a dial rather than a decision, folded away until asked
/// for. Collapsed on open, always — an advanced section that remembers being
/// open stops being an advanced section.
struct AdvancedDisclosure<Content: View>: View {
    var title = "Advanced"
    @ViewBuilder var content: Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)

            if expanded {
                content
                    // Opacity only. `.move(edge: .top)` slides the cards up
                    // through the chevron row on the way in and out — SwiftUI
                    // doesn't clip a transition to its container, so for the
                    // length of the animation the content is drawn over the
                    // header it is supposed to be underneath.
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The row shape the fundamentals list is made of: what it is, what it is set
/// to right now, and the button that opens the rest.
struct SettingsDialogRow: View {
    let label: String
    let value: String
    let action: String
    let open: () -> Void

    var body: some View {
        SettingsRow(label: label, description: value, wideControl: true) {
            Button(action, action: open)
        }
    }
}
