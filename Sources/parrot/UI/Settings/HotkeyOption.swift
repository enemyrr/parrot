import SwiftUI

/// One selectable modifier, drawn as the key it is.
struct HotkeyOption: View {
    let hotkey: Hotkey
    let selected: Bool
    var disabled = false
    /// True while the real key is physically held. The cap then does what a key
    /// does — goes down and lights — so the answer to "is parrot seeing this?"
    /// is the key itself rather than a sentence about it.
    var pressed = false
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Text(hotkey.modifiers.symbols)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .frame(height: 20)
                Text(hotkey.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 62, height: 54)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.panelCornerRadius, style: .continuous)
                    .fill(fill)
            )
            .shadow(color: Color.accentColor.opacity(pressed ? 0.35 : 0), radius: 7)
            // One ring, one width — the fill is what carries selection, the
            // same way it does on the provider chips and the sample cards.
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.panelCornerRadius, style: .continuous)
                    .strokeBorder(
                        selected || pressed ? Color.accentColor : SettingsPalette.keycapBorder,
                        lineWidth: 1
                    )
            )
            .opacity(disabled ? 0.35 : 1)
            // Down, not up: a held key travels the way a real one does, and the
            // fill is what carries the "seen" part.
            .scaleEffect(pressed ? 0.95 : (hovering && !selected && !disabled ? 1.03 : 1))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: selected)
            // Faster than the selection spring — this one is answering a
            // keypress, and anything slower reads as lag rather than as the cap
            // going down under the finger.
            .animation(.spring(response: 0.16, dampingFraction: 0.72), value: pressed)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(hotkey.displayName)
        .accessibilityValue(pressed ? "Held" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Three depths of the same accent: unselected, chosen, and chosen *and*
    /// under a finger. A held cap has to be unmistakably brighter than a merely
    /// selected one, or the whole point of lighting it is lost.
    private var fill: Color {
        if pressed { return Color.accentColor.opacity(0.42) }
        if selected { return Color.accentColor.opacity(0.16) }
        return SettingsPalette.keycapFill
    }
}
