import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        /// Hands-free — same waveform, plus a lock so it's unmistakable.
        case latched
        case transcribing
        /// Squawk only: transcription is done and the model has it. Split out
        /// from `.transcribing` because it is the wait with no predictable
        /// length, and sitting through it not knowing that is the worst of it.
        case thinking
    }

    /// The panel is deliberately larger than the pill: the slide-in travel and
    /// the glass shadow both need room outside the pill or they get clipped.
    private static let panelSize = NSSize(width: 260, height: 120)
    /// Gap between the panel's bottom edge and the pill.
    static let pillInset: CGFloat = 28
    /// Where the pill rests above the bottom of the screen.
    private static let bottomMargin: CGFloat = 32

    private var window: NSPanel?
    private let model = OverlayModel()

    init(sensitivity: Double = 1) {
        model.sensitivity = Float(sensitivity)
    }

    /// Live sensitivity trim — used by the preview to dial in against a real mic.
    func setSensitivity(_ value: Double) {
        model.sensitivity = Float(min(3, max(0.25, value)))
    }

    var sensitivity: Double { Double(model.sensitivity) }

    /// Current meter internals: input, learned room floor, gate and output.
    var readout: (db: Float, noiseFloor: Float, floor: Float, level: Float) {
        (model.lastDb, model.noiseFloorDb, model.floorDb, model.level)
    }

    func show(_ state: State, mode: DictationMode = .dictate) {
        ensureWindow()
        // Set before the state so the first layout of an appearing pill is
        // already wearing the right mode — switching it a tick later would read
        // as the pill changing its mind.
        model.mode = mode
        if state == .recording {
            model.reset()
        }
        model.startTicking()
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // The off-screen layout draws `lastVisible`, so point it at the
            // incoming state before that first pass.
            model.lastVisible = state
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        model.state = .hidden
        // Let the slide-down play out before yanking the window — otherwise it
        // just pops away.
        let window = self.window
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayPill.exitDuration) { [model] in
            // A show() during the grace period wins — don't yank its window.
            guard model.state == .hidden else { return }
            window?.orderOut(nil)
            model.stopTicking()
        }
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws its own shadow; AppKit's would be derived from the
        // (mostly empty) panel and goes stale as the content animates.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Matches the pill's pinned dark scheme — drives the AppKit-side material
        // on the pre-Tahoe fallback path.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        // Offset by the inset so the pill — not the panel — lands on the margin.
        let y = visible.minY + Self.bottomMargin - Self.pillInset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state for the SwiftUI pill.
///
/// The visuals run off a fixed-rate tick rather than the audio callback: taps
/// arrive every ~85ms (4096 frames), which is both too slow and too jittery to
/// scroll a waveform against. `pushLevel` only parks the newest reading; the
/// tick does the smoothing and advances the history.
@MainActor
final class OverlayModel: ObservableObject {
    /// Columns in the scrolling meter — ~1s of speech on screen at
    /// `columnsPerSecond`.
    static let columns = 14
    /// Levels smooth at display rate so the Siri line moves fluidly; the bar
    /// history advances at a quarter of that, which is the readable scroll
    /// speed. Driving both off one slow tick made the line step visibly.
    private static let tickRate: Double = 60
    private static let columnsPerSecond: Double = 15
    private static let ticksPerColumn = Int(tickRate / columnsPerSecond)
    /// Room tone varies hugely by mic and room — a measured MacBook mic in a
    /// quiet room still sits near -42 dBFS, well above any fixed floor worth
    /// picking. So the floor tracks the room instead of being guessed, and the
    /// meter spans a fixed dynamic range above it.
    private static let baseMarginDb: Float = 11
    /// Only samples within this much of the floor count as room tone and are
    /// allowed to raise it. Anything louder is treated as signal.
    private static let roomBandDb: Float = 6
    /// Where the top of the meter sits, in absolute dBFS.
    ///
    /// Anchored to the voice rather than to the floor: how loud you talk
    /// doesn't depend on how quiet the room is (measured peaks land near
    /// -18dB either way). Deriving the ceiling from the floor instead meant
    /// the quieter the room, the more the meter pinned — in a near-silent one
    /// it sat at full scale through most of a sentence, which carries no
    /// information above the pin.
    private static let speechCeilingDb: Float = -17
    /// Floor in a room loud enough that the gate has been capped, where the
    /// absolute ceiling would otherwise sit too close to the gate.
    private static let minRangeDb: Float = 16
    /// Hard ceiling on the gate, independent of the learned floor.
    ///
    /// The floor + margin rule alone only holds in a quiet room. In a noisier
    /// one the floor rises, and with it the gate — measured speech sits at a
    /// median of -29dB, so a room floor of -35 would push the gate above half
    /// of normal speech and the meter would sit dead while you talked. Capping
    /// it here means a loud room costs you some noise on screen rather than
    /// costing you the signal entirely.
    private static let maxGateDb: Float = -30
    /// Starts above a typical room so the fast-falling follower converges down
    /// onto it in well under a second. Seeding it low instead meant crawling up
    /// at the slow rate, with a second of room noise on screen while it did.
    private static let initialFloorDb: Float = -30
    /// Shapes the gate → ceiling response. >1 compresses the quiet end.
    private static let responseCurve: Float = 1.5
    /// Below this, snap to true zero — the line has to lie flat when you stop
    /// talking or you can't tell speech from silence.
    private static let gate: Float = 0.02

    @Published var state: RecordingOverlay.State = .hidden {
        didSet { if state != .hidden { lastVisible = state } }
    }
    /// What the pill keeps drawing on its way out. `state` flips to `.hidden`
    /// the instant the exit starts, so switching content on it swapped the
    /// spinner back to the waveform for the length of the collapse.
    var lastVisible: RecordingOverlay.State = .recording
    /// Drives the visualiser, the accent and the glyph — the three things that
    /// make the two modes unmistakable at a glance.
    @Published var mode: DictationMode = .dictate
    /// Oldest sample first, so the newest lands on the right and the row
    /// travels right → left.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: columns)
    @Published private(set) var level: Float = 0

    /// 1.0 is the default. Higher drops the noise floor, so quieter mics and
    /// softer voices still fill the meter.
    var sensitivity: Float = 1

    private var raw: Float = 0
    private var timer: Timer?
    private var tickCount = 0

    func pushLevel(_ rms: Float) {
        // dBFS against a floor that follows the room. The old
        // `sqrt(rms) * 3.4` reached full scale at RMS 0.086 — room tone alone
        // showed ~30% and any speech pinned every bar, hence the hair trigger.
        let db = 20 * log10(max(rms, 1e-7))

        // Falls fast onto quiet passages. Rising is gated to samples already
        // near the floor: anything well above it is speech, and speech must not
        // be allowed to move the floor at all. Measured, 15s of continuous
        // talking lifted it 3.5dB — the meter got steadily less responsive the
        // longer you spoke, which a 300s hands-free session would make severe.
        // Deliberately survives `reset()`: it's a property of the room, not of
        // one utterance, and push-to-talk clips are too short to re-learn it.
        lastDb = db
        if db < noiseFloorDb {
            noiseFloorDb += (db - noiseFloorDb) * 0.25
        } else if db < noiseFloorDb + Self.roomBandDb {
            noiseFloorDb += (db - noiseFloorDb) * 0.01
        }

        floorDb = min(
            noiseFloorDb + Self.baseMarginDb / max(0.25, sensitivity),
            Self.maxGateDb
        )
        let ceiling = max(floorDb + Self.minRangeDb, Self.speechCeilingDb)
        let normalised = min(1, max(0, (db - floorDb) / (ceiling - floorDb)))
        // Curved rather than linear. The gap between room noise and speech is
        // wider than the gap in dB suggests, and a linear map gave a fan or a
        // chair creak a bar you could read across the room. The exponent leaves
        // the top of the range nearly untouched (0.8 → 0.72) and flattens the
        // bottom (0.1 → 0.03), so only the meter's noise end loses travel.
        raw = pow(normalised, Self.responseCurve)
    }

    /// Live meter internals, for `overlay-preview --debug-levels`.
    private(set) var lastDb: Float = -120
    private(set) var noiseFloorDb: Float = initialFloorDb
    private(set) var floorDb: Float = initialFloorDb

    func reset() {
        raw = 0
        level = 0
        tickCount = 0
        history = Array(repeating: 0, count: Self.columns)
    }

    /// Only runs while the pill is on screen — this is a background daemon.
    func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.tickRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the meter keeps moving while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// Internal rather than private so the meter can be driven deterministically
    /// off-clock when checking its response across different room noise levels.
    func tick() {
        // Fast attack, slow release — a level meter should snap to a transient
        // and fall away gently, not ease symmetrically in both directions.
        // Coefficients are per-tick at 60Hz.
        let coeff: Float = raw > level ? 0.2 : 0.05
        var next = level + (raw - level) * coeff
        if next < Self.gate && raw < Self.gate { next = 0 }
        level = next

        tickCount += 1
        guard tickCount % Self.ticksPerColumn == 0 else { return }

        // Newest sample enters on the right and the row shifts left, matching
        // the direction Apple's dictation meter travels.
        history.removeFirst()
        history.append(level)
    }
}

struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    static let exitDuration: TimeInterval = 0.2
    /// How far below its resting place the pill starts / ends up.
    private static let travel: CGFloat = 24

    private var isHidden: Bool { model.state == .hidden }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // Scrim sits above the glass, below the waveform: `Glass.tint` barely
            // darkens, and behind-window glass ignores the dark color scheme, so
            // without this the pill goes near-white over bright backdrops.
            .background(Capsule().fill(.black.opacity(0.32)))
            .glassPill()
            .shadow(color: .black.opacity(0.30), radius: 14, y: 5)
            .opacity(isHidden ? 0 : 1)
            .scaleEffect(isHidden ? 0.9 : 1, anchor: .bottom)
            .offset(y: isHidden ? Self.travel : 0)
            .animation(
                isHidden
                    ? .easeIn(duration: Self.exitDuration)
                    : .spring(response: 0.36, dampingFraction: 0.7),
                value: model.state
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, RecordingOverlay.pillInset)
            // Pinned dark regardless of system appearance — the pill is a HUD, and
            // its light-mode materials/controls read as washed out over the glass.
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let shown = isHidden ? model.lastVisible : model.state
        let accent = OverlayPill.accent(model.mode, shown)
        switch shown {
        case .hidden, .recording:
            Waveform(model: model, accent: accent)
        case .latched:
            HStack(spacing: 7) {
                Waveform(model: model, accent: accent)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.flat)
                    .transition(.blurReplace)
            }
        case .transcribing, .thinking:
            BusySpinner(accent: accent)
                .frame(width: Waveform.size.width, height: Waveform.size.height)
                // Identified by state so the warm spinner and the violet one
                // are two views crossfading, not one view whose gradient jumps
                // — `AnyShapeStyle` won't interpolate on its own.
                .id(shown)
                .transition(.blurReplace)
        }
    }

    /// Brightened from the old solid-pill blue — glass eats contrast. Squawk
    /// runs warm against it: the two pills have to be tellable apart in
    /// peripheral vision, and hue carries further than shape does. With the
    /// mode badge gone, colour and waveform are the whole distinction.
    ///
    /// Squawk's two waits are not the same wait. Transcribing is still about
    /// your voice and stays warm; the model working is the one wait whose
    /// length nobody can predict, and it goes violet. The shift is the only
    /// place the user is told which of the two they are sitting through.
    static func accent(_ mode: DictationMode, _ state: RecordingOverlay.State) -> OverlayAccent {
        switch mode {
        // A file transcription never raises the pill — there is no microphone
        // hot and nothing to reassure anyone about. It shares dictation's look
        // only so this switch has an answer for a mode it can't be shown in.
        case .dictate, .file: return .dictate
        case .squawk: return state == .thinking ? .thinking : .squawk
        }
    }
}

/// A hue and the hue it leans toward, lit by a highlight that travels across
/// both. One flat colour goes dead under glass, and a full spectrum is no
/// colour at all — two stops a short hue apart read as one colour catching
/// light, which keeps the accent recognisable from the corner of your eye.
struct OverlayAccent {
    let base: Color
    let tip: Color

    static let dictate = OverlayAccent(
        base: Color(red: 200/255, green: 222/255, blue: 255/255),
        tip: Color(red: 168/255, green: 205/255, blue: 255/255)
    )
    /// Where the old gold was, leaning into coral.
    static let squawk = OverlayAccent(
        base: Color(red: 255/255, green: 216/255, blue: 168/255),
        tip: Color(red: 255/255, green: 158/255, blue: 138/255)
    )
    /// Deliberately far from the dictate blue — the spinner is small, and a
    /// violet that drifted toward periwinkle would read as the wrong mode.
    static let thinking = OverlayAccent(
        base: Color(red: 201/255, green: 162/255, blue: 255/255),
        tip: Color(red: 232/255, green: 166/255, blue: 255/255)
    )

    /// For anything too small to carry a gradient — a 10pt glyph reads as mud.
    var flat: Color { base }

    var style: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: [base, tip], startPoint: .leading, endPoint: .trailing))
    }

    /// Back to `base` at the far end so the sweep closes on itself — an
    /// unmatched seam turning under your eye is all you'd be able to look at.
    var angularStyle: AnyShapeStyle {
        AnyShapeStyle(AngularGradient(colors: [base, tip, base], center: .center))
    }

    /// Same trick horizontally: the wave runs base → tip → base so neither end
    /// of the stroke is a different colour from the other.
    func waveShading(width: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: [base, tip, base]),
            startPoint: .zero,
            endPoint: CGPoint(x: width, y: 0)
        )
    }
}


private extension View {
    /// Liquid Glass where the OS has it, a HUD vibrancy capsule everywhere else.
    @ViewBuilder
    func glassPill() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(VibrancyBackdrop())
                .clipShape(.capsule)
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
        }
    }
}

/// Accent-coloured spinner — `ProgressView` renders as a grey system spinner
/// here (`.tint` doesn't reach `NSProgressIndicator`) and clashes with the glass.
private struct BusySpinner: View {
    let accent: OverlayAccent

    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate * 0.6
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    accent.angularStyle,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
                .frame(width: 14, height: 14)
        }
    }
}

/// Pre-Tahoe fallback: real behind-window blur, since the panel is transparent.
private struct VibrancyBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Dispatches to the mode's visualiser. Both fill the same slot, so the pill
/// keeps one shape whichever is running.
private struct Waveform: View {
    @ObservedObject var model: OverlayModel
    let accent: OverlayAccent

    static let size = CGSize(width: 54, height: 22)

    var body: some View {
        Group {
            switch model.mode {
            case .dictate, .file:
                TravellingBars(history: model.history, accent: accent)
            case .squawk:
                SiriLine(level: model.level, accent: accent)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Scrolling meter. Each bar is one sample, so the row reads as a stretch of
/// time rather than one number drawn N times. Newest is rightmost.
private struct TravellingBars: View {
    let history: [Float]
    let accent: OverlayAccent

    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(accent.style)
                    // Animating height rather than scaleEffect(y:) keeps the
                    // round caps circular instead of squashing them.
                    .frame(
                        width: Self.barWidth,
                        height: max(Self.barWidth, CGFloat(level) * Waveform.size.height)
                    )
            }
        }
    }
}

/// Two stroked waves that lie flat when silent and swell with your voice.
private struct SiriLine: View {
    let level: Float
    let accent: OverlayAccent

    /// Sweeps per second for the specular highlight. Slow — a glint crossing a
    /// curved surface, not something scrolling past.
    private static let sheenSpeed = 0.32
    /// Half-width of the highlight, as a fraction of the wave. Wide enough to
    /// look like light and not like a bar travelling along the stroke.
    private static let sheenSpread: CGFloat = 0.3

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                wave(t: t, cycles: 1.6, speed: 0.9, amp: 1, opacity: 1)
                // Half a sweep out of step with the front wave, so the light
                // crosses the two strokes at different moments rather than
                // lighting the whole visualiser at once.
                wave(t: t, cycles: 2.4, speed: -0.65, amp: 0.6, opacity: 0.45, sheenPhase: 0.5)
            }
        }
    }

    private func wave(
        t: Double,
        cycles: Double,
        speed: Double,
        amp: Double,
        opacity: Double,
        sheenPhase: Double = 0
    ) -> some View {
        Canvas { context, size in
            let mid = size.height / 2
            let peak = Double(level) * (size.height / 2 - 1) * amp
            var path = Path()
            for x in stride(from: 0.0, through: size.width, by: 1) {
                let u = x / size.width
                // Taper to flat at both ends so it reads as one gesture.
                let taper = pow(sin(u * .pi), 0.8)
                let y = mid + sin(u * .pi * 2 * cycles + t * speed) * peak * taper
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            // Opacity on the context rather than the colour — a gradient has no
            // single colour to fade, and this way the back wave's sheen is
            // damped by exactly as much as the wave carrying it.
            context.opacity = opacity
            context.stroke(path, with: accent.waveShading(width: size.width), style: stroke)
            context.stroke(
                path,
                with: Self.sheenShading(width: size.width, phase: t * Self.sheenSpeed + sheenPhase, level: level),
                style: stroke
            )
        }
    }

    /// A narrow band of light sliding along the stroke. This is where the
    /// richness comes from: two hues stay legible from the corner of your eye,
    /// and the life is in light moving over them rather than in more colours.
    ///
    /// Transparent at both ends, so the gradient clamps to nothing outside the
    /// band and the rest of the wave keeps its own colour.
    private static func sheenShading(
        width: CGFloat,
        phase: Double,
        level: Float
    ) -> GraphicsContext.Shading {
        // Brightest while you are actually talking — a glint that answers the
        // voice, not a loop running on its own whether you speak or not.
        let strength = 0.16 + 0.5 * Double(level)
        let half = width * sheenSpread
        // Enters and leaves fully off the wave, rather than appearing at the edge.
        let centre = -half + (width + half * 2) * CGFloat(phase - phase.rounded(.down))
        return .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(strength), location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: centre - half, y: 0),
            endPoint: CGPoint(x: centre + half, y: 0)
        )
    }
}

