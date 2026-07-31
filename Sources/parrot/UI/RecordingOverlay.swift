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

    init(style: OverlayStyle = .bars, sensitivity: Double = 1) {
        model.style = style
        model.sensitivity = Float(sensitivity)
    }

    /// Swap visualiser without tearing down the window — used by the preview.
    func setStyle(_ style: OverlayStyle) {
        model.style = style
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

    func show(_ state: State) {
        ensureWindow()
        if state == .recording {
            model.reset()
        }
        model.startTicking()
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
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
    private static let baseMarginDb: Float = 8
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
    /// Below this, snap to true zero — the line has to lie flat when you stop
    /// talking or you can't tell speech from silence.
    private static let gate: Float = 0.02

    @Published var state: RecordingOverlay.State = .hidden
    @Published var style: OverlayStyle = .bars
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
        let normalised = (db - floorDb) / (ceiling - floorDb)
        raw = min(1, max(0, normalised))
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
            .padding(.vertical, 10)
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
        switch model.state {
        case .hidden, .recording:
            Waveform(model: model)
        case .latched:
            HStack(spacing: 7) {
                Waveform(model: model)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OverlayPill.accent)
                    .transition(.blurReplace)
            }
        case .transcribing:
            BusySpinner()
                .frame(width: Waveform.size.width, height: Waveform.size.height)
                .transition(.blurReplace)
        }
    }

    /// Brightened from the old solid-pill blue — glass eats contrast.
    static let accent = Color(red: 200/255, green: 222/255, blue: 255/255)
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
    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate * 0.6
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    OverlayPill.accent,
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

/// Dispatches to the configured visualiser. All three fill the same slot, so
/// the pill keeps one shape whichever you pick.
private struct Waveform: View {
    @ObservedObject var model: OverlayModel

    static let size = CGSize(width: 54, height: 22)

    var body: some View {
        Group {
            switch model.style {
            case .bars: TravellingBars(history: model.history)
            case .line: SiriLine(level: model.level)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Scrolling meter. Each bar is one sample, so the row reads as a stretch of
/// time rather than one number drawn N times. Newest is rightmost.
private struct TravellingBars: View {
    let history: [Float]

    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(OverlayPill.accent)
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

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                wave(t: t, cycles: 1.6, speed: 0.9, amp: 1, opacity: 1)
                wave(t: t, cycles: 2.4, speed: -0.65, amp: 0.6, opacity: 0.45)
            }
        }
    }

    private func wave(t: Double, cycles: Double, speed: Double, amp: Double, opacity: Double) -> some View {
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
            context.stroke(
                path,
                with: .color(OverlayPill.accent.opacity(opacity)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

