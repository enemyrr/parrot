import AppKit
import SwiftUI

/// The Home page's headline — "Hold ⌥ to dictate anywhere" — with the key drawn
/// as the physical thing rather than named in text.
///
/// Split out of `HomePane` because the sizes here are relational: the cap
/// against the sentence, the sentence against the card below it. They were
/// picked by putting the real view on screen and switching between variants,
/// which is the only way to judge any of them.
struct HomeHero: View {
    let hotkey: Hotkey
    let subline: String
    let openShortcuts: () -> Void

    /// The sentence the key sits inside. The cap and its legend are sized
    /// against this, not against each other.
    static let sentenceSize: CGFloat = 23

    /// Extra room under the hero, on top of the page's own section spacing.
    /// Without it the headline sits on the same rhythm as everything below and
    /// reads as row zero of the settings list rather than as the page speaking.
    private static let bottomGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Baseline, not centre: an inline object centred against the line
            // box floats, because a 40pt cap and a 23pt line have nothing in
            // common to centre on.
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Hold")
                HeroKeycap(hotkey: hotkey, open: openShortcuts)
                // The lead-in and the cycling word are one phrase, so they sit
                // closer than the sentence's own spacing.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("to dictate")
                    RotatingWords(words: ["anywhere", "in Slack", "in Cursor", "in Mail"])
                }
            }
            .font(.system(size: Self.sentenceSize, weight: .medium))

            Text(subline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                // With both squawk and latch bound the line runs long enough to
                // wrap. Same guard every other explanatory line in the window
                // carries, so it wraps rather than truncating to one.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Self.bottomGap)
    }

    /// Half the sentence's x-height: how far above the baseline an inline
    /// object's centre has to hang to sit in the line rather than on it.
    /// Measured off the font rather than guessed, so it stays right if the
    /// headline is ever resized.
    static var xHeightHalf: CGFloat {
        NSFont.systemFont(ofSize: sentenceSize, weight: .medium).xHeight / 2
    }
}

// MARK: - Keycap

/// The hotkey drawn as the key it is, sitting inside the headline sentence.
/// Clicking it opens the bindings dialog — the cap *is* the setting, so the
/// cap is the way in.
///
/// Styled after the physical thing: MacBook keys are matte black in every
/// appearance, with a tight corner radius and no shine. No drop shadow —
/// a real key sits nearly flush, so depth comes from a crisp 1pt lip under
/// the bottom edge instead, and hovering brightens the face like backlight.
private struct HeroKeycap: View {
    let hotkey: Hotkey
    let open: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: open) {
            legend
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.9))
                .background(KeycapMetrics.shape.fill(face))
                .overlay(
                    // The machined sheen along the top edge — also what keeps
                    // a black key from melting into a dark window.
                    KeycapMetrics.shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .contentShape(KeycapMetrics.shape)
        }
        .buttonStyle(KeycapPressStyle())
        // A box carries no text baseline of its own, so SwiftUI would fall back
        // to its bottom edge and hang the whole cap above the line. Put the
        // cap's centre on the sentence's x-height centre instead.
        .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + HomeHero.xHeightHalf }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Change key bindings")
        .accessibilityLabel("Dictation key: \(hotkey.displayName). Change key bindings")
    }

    /// Printed like the physical cap: fn gets the globe bottom-left with the
    /// small "fn" top-right, other bare modifiers get their symbol in the
    /// corner over the lowercase name, and a chord gets its label centered.
    @ViewBuilder
    private var legend: some View {
        if hotkey == .fn {
            ZStack {
                Text("fn")
                    .font(.system(size: KeycapMetrics.glyph(11), weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                Image(systemName: "globe")
                    .font(.system(size: KeycapMetrics.glyph(13)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .padding(KeycapMetrics.padding)
            .frame(width: KeycapMetrics.size, height: KeycapMetrics.size)
        } else if hotkey.isBareModifier, let name = hotkey.modifiers.singleName {
            ZStack {
                Text(hotkey.modifiers.symbols)
                    .font(.system(size: KeycapMetrics.glyph(14), weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                Text(name.lowercased())
                    .font(.system(size: KeycapMetrics.glyph(10)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .padding(KeycapMetrics.padding)
            .frame(minWidth: KeycapMetrics.size)
            .frame(height: KeycapMetrics.size)
        } else {
            Text(hotkey.displayLabel)
                .font(.system(size: KeycapMetrics.glyph(16), weight: .medium))
                .padding(.horizontal, KeycapMetrics.horizontalPadding)
                .frame(minWidth: KeycapMetrics.size)
                .frame(height: KeycapMetrics.size)
        }
    }

    private var face: Color {
        let resting = scheme == .dark ? Color(white: 0.2) : Color(white: 0.13)
        return hovering ? resting.opacity(0.85) : resting
    }
}

/// Everything the cap's drawing derives from its size.
///
/// The constants are the ones the key was originally drawn with at 52pt, kept
/// as ratios of `size` so shrinking the cap gives the same key rather than a
/// different one.
private enum KeycapMetrics {
    /// Square footprint of a bare modifier; chords keep this height and widen.
    /// At the 52 this was drawn at, the cap was nearly twice the sentence's line
    /// height — it stopped being a word in the sentence and became an object
    /// parked between two labels.
    static let size: CGFloat = 40

    /// What those ratios were taken from.
    private static let reference: CGFloat = 52
    private static let scale = size / reference

    /// The legend gets a trim on top of the cap's scale. Shrinking it
    /// proportionally takes "fn" to 8pt, which is a smudge rather than a label,
    /// and the printing is the part that has to hold its own against 23pt text.
    private static let legendTrim: CGFloat = 1.2

    static let padding: CGFloat = 8 * scale
    static let horizontalPadding: CGFloat = 14 * scale

    /// Rounded to a half point, because SF at an arbitrary fractional size
    /// hints badly at legend scale.
    static func glyph(_ base: CGFloat) -> CGFloat {
        (base * scale * legendTrim * 2).rounded() / 2
    }

    /// Tighter than the cards on purpose: a keycap's corners are barely
    /// rounded, and the card radius made it read as a pill.
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(4, 5 * scale), style: .continuous)
    }
}

/// Down onto the lip, like a key. The lip is a fixed 1pt sliver of the key's
/// side peeking out below the cap; pressing offsets the cap over it, so the
/// key sinks flush with no shadow involved.
private struct KeycapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .background(KeycapMetrics.shape.fill(.black.opacity(0.8)).offset(y: 1))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Rotating words

/// The tail of the headline, cycling through where dictation lands. One place
/// at a time rather than a list: the point is that it works everywhere, and a
/// comma-separated four makes that a claim to read instead of watch.
///
/// Each word carries its own preposition. A shared one in the sentence has to
/// govern every word in the list, and "dictate on Messages" is broken English
/// making the claim that it works there.
private struct RotatingWords: View {
    let words: [String]
    var interval: Duration = .milliseconds(2000)

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rotating in a window nobody is looking at is pure battery. `.inactive`
    /// covers the case this is actually costing something: settings opened,
    /// clicked away from, and left open for the rest of the day.
    @Environment(\.controlActiveState) private var activeState

    private var isActive: Bool { activeState != .inactive }

    var body: some View {
        // The clip belongs to the container, not the word: a `.clipped()` on
        // the word itself travels with it and clips nothing.
        ZStack(alignment: .leading) {
            // Laid out but never drawn, purely so the stack measures to the
            // longest word. Sized to whatever is showing, the sentence's right
            // edge — and the clip around it — slide in and out every cycle.
            ForEach(words.indices, id: \.self) { i in
                Text(words[i]).italic().hidden()
            }
            Text(words[index])
                .italic()
                .id(index)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
        }
        .clipped()
        .task(id: isActive) {
            // Tied to the view's lifetime, so it stops with the pane and isn't
            // restarted by every redraw the way a Timer publisher is. Keyed on
            // `isActive` so resigning active cancels it rather than leaving it
            // spinning behind another app's window.
            guard isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    index = (index + 1) % words.count
                }
            }
        }
        .accessibilityLabel(words.joined(separator: ", "))
    }
}
