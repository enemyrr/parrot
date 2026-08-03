import SwiftUI

/// A segmented control with a Liquid Glass puck that slides between segments.
///
/// `.pickerStyle(.segmented)` still draws AppKit's pre-Tahoe bezel, which makes
/// it the one control in the window that doesn't belong to the same design as
/// everything around it.
struct GlassTabs<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        /// SF Symbol shown before the title. Nil for a plain word — two tabs
        /// don't need icons to be told apart, six do.
        var symbol: String? = nil

        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    /// Let the track scroll sideways when it outgrows the window.
    ///
    /// Off for a fixed pair of tabs, which can't overgrow. On where the user
    /// adds them: a capsule that wraps to two rows stops reading as a
    /// segmented control, and one that clips loses whichever tab is last.
    var scrollable = false
    /// Renders a `+` as the last segment when set.
    ///
    /// Inside the track, not beside it: what it adds is a tab, so it belongs to
    /// the same control. Pinned outside it floats against the window's right
    /// edge with a gap where the tabs ran out, which reads as a button acting on
    /// the pane rather than one that appends to the row it is nowhere near.
    var onAdd: (() -> Void)?
    var addHelp = "Add"

    @Namespace private var puckNamespace
    @State private var hovered: Value?
    @State private var addHovered = false

    var body: some View {
        if scrollable {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Room for the puck's shadow, which a scroll view clips to
                    // its content height.
                    track.padding(.vertical, 1)
                }
                // A tab picked from off-screen — or one just added — has to come
                // into view, or the selection appears not to have taken. The
                // `+` rides along at the end, which is also where the new tab
                // lands.
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        } else {
            track
        }
    }

    private var track: some View {
        HStack(spacing: 2) {
            ForEach(options) { segment($0) }
            if let onAdd {
                addButton(onAdd)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(SettingsPalette.tabTrackFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(SettingsPalette.cardBorder.opacity(0.5), lineWidth: 0.5)
                )
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selection)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection

        // Weight stays put across states — reflowing to semibold on selection
        // resizes the segment, and the puck chases a target that's still moving.
        return HStack(spacing: 5) {
            if let symbol = option.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(option.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                puck.matchedGeometryEffect(id: "puck", in: puckNamespace)
            } else if hovered == option.value {
                Capsule(style: .continuous).fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { selection = option.value }
        .onHover { inside in
            if inside {
                hovered = option.value
            } else if hovered == option.value {
                hovered = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // A glyph and a line of text of the same point size are not the
                // same height, and a `+` an even pixel shorter than the tabs
                // beside it makes the whole track look misaligned. Sized off a
                // hidden segment label instead, so it matches by construction.
                Text("+").font(.system(size: 12, weight: .semibold)).hidden()
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(addHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if addHovered {
                    Capsule(style: .continuous).fill(.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { addHovered = $0 }
        .help(addHelp)
        .accessibilityLabel(addHelp)
    }

    /// Liquid Glass where the OS has it, a raised control surface everywhere else.
    @ViewBuilder
    private var puck: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Capsule(style: .continuous)
                .fill(SettingsPalette.cardBackground)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(SettingsPalette.cardBorder, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
        }
    }
}
