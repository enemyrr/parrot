import AppKit
import SwiftUI

/// One scrap, and the shot that launched it.
///
/// Everything about the flight is fixed at launch and the position is a pure
/// function of elapsed time — no per-frame state to keep, nothing to drift out
/// of sync, and the burst looks the same however long a frame takes to draw.
struct ConfettiPiece {
    /// Which cannon fired it. The two are mirror images, so this is the only
    /// thing that differs between them.
    let fromLeft: Bool
    /// Muzzle velocity, in points per second.
    let vx: Double
    let vy: Double
    /// Barely any — a cannon fires at once. Just enough that the charge doesn't
    /// leave as one solid block.
    let delay: Double
    /// Turns over the flight. Signed, so half of them tumble the other way.
    let spin: Double
    /// How fast it turns edge-on, which is what stops each piece reading as a
    /// flat rectangle being dragged along an arc.
    let flutter: Double
    let size: CGSize
    let color: Color
}

/// Two cannons' worth of paper, sized to the surface they're fired across.
///
/// The velocities are fractions of that surface rather than absolute numbers,
/// so the same volley reads identically on a 13" laptop and a 6K display. Fixed
/// speeds tuned against one screen look like a firework on the other.
struct ConfettiVolley {
    let pieces: [ConfettiPiece]
    /// Downward pull, points per second squared.
    let gravity: Double
    /// How quickly sideways travel bleeds off. Air does most of the work of
    /// making a popper look like a popper — with none, the scraps carry on in
    /// straight lines and it reads as a sprinkler; with too much the plumes
    /// stall in their corners and never cross.
    let drag: Double

    /// Four colours, no more. Confetti drawn from the whole spectrum looks like
    /// a test pattern; a small palette with the app's own accent in it looks
    /// like it belongs here.
    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.51, blue: 0.98),
        Color(red: 0.36, green: 0.78, blue: 0.47),
        Color(red: 0.98, green: 0.71, blue: 0.25),
        Color(red: 0.91, green: 0.44, blue: 0.62),
    ]

    /// The longest anything stays up: the steepest shot's whole flight, plus its
    /// fuse. Measured off the pieces rather than restated from the numbers in
    /// `cannons` — retuning the cone there would otherwise close the panel over
    /// confetti still in the air.
    var duration: TimeInterval {
        pieces.map { flightTime(of: $0) + $0.delay }.max() ?? 0
    }

    /// One cannon in each bottom corner, both firing up and inward.
    static func cannons(across size: CGSize, perSide: Int = 70) -> ConfettiVolley {
        // Chosen together: at this gravity a shot leaves at between 1.6 and 2.5
        // screen-heights per second, which tops out between half and one and a
        // quarter screens up. The steep ones going clean off the top edge are
        // the point — a burst where every piece stays politely in frame reads
        // as an animation, not as something fired.
        let gravity = 2.6 * size.height

        let pieces = [true, false].flatMap { fromLeft in
            (0..<perSide).map { index in
                ConfettiPiece(
                    fromLeft: fromLeft,
                    // A wide cone. The shallow shots are the ones that make it
                    // to the far side, and without them the two plumes never
                    // meet in the middle.
                    vx: size.width * Double.random(in: 0.28...0.85) * (fromLeft ? 1 : -1),
                    vy: -size.height * Double.random(in: 1.6...2.5),
                    delay: Double.random(in: 0...0.07),
                    spin: Double.random(in: 0.8...2.6) * (index.isMultiple(of: 2) ? 1 : -1),
                    flutter: Double.random(in: 3...7),
                    size: CGSize(
                        width: Double.random(in: 6...10),
                        height: Double.random(in: 10...16)
                    ),
                    color: palette[index % palette.count]
                )
            }
        }

        return ConfettiVolley(pieces: pieces, gravity: gravity, drag: 0.85)
    }

    /// Back down to where it started. What the fade is measured against.
    func flightTime(of piece: ConfettiPiece) -> Double { -2 * piece.vy / gravity }
}

/// Both cannons, drawn in one `Canvas` pass.
///
/// A `Canvas` rather than a hundred and forty `Rectangle`s: this is the one
/// moment in parrot where a dropped frame would be obvious, and that many
/// animating views is that many layout passes a frame for something nobody can
/// interact with.
struct ConfettiBurst: View {
    let volley: ConfettiVolley
    let start: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in volley.pieces {
                    draw(piece, at: elapsed, in: size, context: context)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        _ piece: ConfettiPiece,
        at elapsed: TimeInterval,
        in size: CGSize,
        context: GraphicsContext
    ) {
        let t = elapsed - piece.delay
        guard t > 0 else { return }

        // Sideways travel under linear drag, which approaches a limit rather
        // than running on forever: distance = v/k · (1 − e^−kt).
        let k = volley.drag
        let travel = piece.vx * (1 - exp(-k * t)) / k
        let muzzle = piece.fromLeft ? -16.0 : size.width + 16
        let x = muzzle + travel

        // Ballistic vertically. Drag here too would flatten the arc into
        // something limp — the fall back down is half of what makes it read as
        // a launch.
        let y = size.height + 18 + piece.vy * t + 0.5 * volley.gravity * t * t
        guard y < size.height + 100 else { return }

        var layer = context
        layer.translateBy(x: x, y: y)
        layer.rotate(by: .degrees(piece.spin * t * 360))
        // Turning edge-on. Squashing to nothing and back is what sells a flat
        // scrap tumbling rather than a rectangle being rotated.
        layer.scaleBy(x: 1, y: cos(t * piece.flutter * .pi))

        // Only at the end of the way back down. Fading through the climb would
        // have the burst going grey while it is still the thing being watched.
        let progress = t / volley.flightTime(of: piece)
        let opacity = progress < 0.8 ? 1 : max(0, 1 - (progress - 0.8) / 0.35)

        layer.fill(
            Path(
                roundedRect: CGRect(
                    x: -piece.size.width / 2,
                    y: -piece.size.height / 2,
                    width: piece.size.width,
                    height: piece.size.height
                ),
                cornerRadius: 1.5
            ),
            with: .color(piece.color.opacity(opacity))
        )
    }
}

// MARK: - Screen overlay

/// Fires the volley across the whole display rather than inside the setup
/// window.
///
/// Confetti confined to a 700-point window is a decoration in a box; the same
/// burst over the desktop is the app celebrating with you. It costs one
/// borderless, click-through panel — the same kind the recording pill already
/// uses — and it means the setup window can close on schedule while the paper
/// is still coming down behind it.
@MainActor
enum ConfettiOverlay {
    /// Held only for the length of the burst. A panel with nothing referencing
    /// it goes away mid-flight.
    private static var panel: NSPanel?

    static func fire(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let frame = screen.frame
        let volley = ConfettiVolley.cannons(across: frame.size)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Over the setup window and everything else on screen. Nothing about
        // this panel can be interacted with, so being on top costs nothing.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Click-through, and non-activating: the burst must not steal focus
        // from whatever the user turns to next.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: ConfettiBurst(volley: volley, start: Date()))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        Self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + volley.duration) {
            // `close`, not `orderOut`: `parrot setup` quits when its last window
            // closes, and a panel that is merely hidden would leave that app
            // running with nothing on screen.
            panel.close()
            if Self.panel === panel { Self.panel = nil }
        }
    }
}
