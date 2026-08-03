import AVFoundation
import ApplicationServices
import SwiftUI

/// The three system states the guided setup walks someone through, polled while
/// the window is open.
///
/// Every one of them is granted somewhere else — a system prompt, System
/// Settings — so there is no event to listen for. Polling is what lets the step
/// tick itself off while the user is still looking at the other window, instead
/// of asking them to come back and press Refresh.
@MainActor
final class OnboardingChecks: ObservableObject {
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()
    /// Only meaningful when Fn is the chosen key; see `watchFnKey`.
    @Published private(set) var fnKey: CheckStatus = .ok

    /// Set by the key step. The Fn check shells out to `defaults`, and running
    /// that every second for someone who picked Option would be paying for an
    /// answer nothing reads.
    var watchFnKey = false {
        didSet { if watchFnKey != oldValue { refresh() } }
    }

    private var timer: Timer?

    var microphoneGranted: Bool { microphone == .authorized }
    var microphoneDenied: Bool { microphone == .denied || microphone == .restricted }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        fnKey = watchFnKey ? DoctorReport.checkFnKeyMapping().status : .ok
    }
}

// MARK: - Key test

/// Watches the modifier keys for as long as the key step is on screen.
///
/// Picking a key is the one step with nothing to grant, which left it as the
/// only screen that asked the user to take parrot's word for it — and Fn is
/// exactly the key most likely to be answered by macOS before parrot ever sees
/// it. So the cap lights the moment the key actually goes down: the same shape
/// as the other steps, press it and watch it answer.
@MainActor
final class KeyProbe: ObservableObject {
    /// The modifiers held right now.
    @Published private(set) var held: HotkeyModifiers = []
    /// Every modifier seen down at least once since the step opened, so a key
    /// that has answered stays answered after the user lets go.
    @Published private(set) var seen: HotkeyModifiers = []

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        // Local catches the press while this window is key, which is where the
        // user is standing. Global covers the rest, and costs nothing when
        // Accessibility hasn't been granted — it simply never fires, and the
        // local one still proves the key.
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(event) }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(event) }
        }
        monitors = [local, global].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        held = []
        seen = []
    }

    func isDown(_ hotkey: Hotkey) -> Bool {
        hotkey.isBareModifier && held.contains(hotkey.modifiers)
    }

    func hasAnswered(_ hotkey: Hotkey) -> Bool {
        hotkey.isBareModifier && seen.contains(hotkey.modifiers)
    }

    private func update(_ event: NSEvent) {
        held = HotkeyModifiers(cgFlags: event.cgEvent?.flags ?? [])
        seen.formUnion(held)
    }
}

// MARK: - Microphone test

/// Runs the microphone for as long as the mic step is on screen.
///
/// A granted permission and a working microphone are not the same thing — the
/// wrong input device is selected often enough that "allowed" is worth nothing
/// on its own. So the step proves it instead of claiming it.
///
/// Its own `AudioCapture` rather than the daemon's: the same window opens with
/// no daemon behind it (`parrot setup`), and the daemon's capture belongs to
/// whatever the hotkey is doing.
@MainActor
final class MicTester: ObservableObject {
    /// The recording pill's meter, reused whole. Its floor tracking and response
    /// curve are the difference between a bar that twitches at room tone and one
    /// that answers your voice — and reusing it means what you see here is what
    /// you'll see while dictating.
    let meter = OverlayModel()

    /// Latched once the meter has clearly seen speech. Latched rather than live
    /// so the caption doesn't flicker back to "say something" between words.
    @Published private(set) var heard = false

    private let capture = AudioCapture()
    private var running = false

    /// Well above room tone, below a normal speaking voice.
    private static let speechLevel: Float = 0.25

    func start() {
        guard !running, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // The mic test has to be of the microphone parrot will actually use.
        capture.preferredDeviceUID = SettingsStore.shared.settings.audio.inputDeviceUID
        capture.onLevel = { [weak self] level in
            // Arrives on the audio thread; the meter is main-actor.
            Task { @MainActor in self?.push(level) }
        }
        do {
            try capture.start()
        } catch {
            return
        }
        meter.startTicking()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        capture.onLevel = nil
        _ = capture.stop()
        meter.stopTicking()
        meter.reset()
        heard = false
    }

    private func push(_ level: Float) {
        meter.pushLevel(level)
        if meter.level > Self.speechLevel { heard = true }
    }
}

/// The meter itself: the pill's travelling bars, scaled up to something you can
/// read across a window.
struct MicMeter: View {
    @ObservedObject var model: OverlayModel

    private static let height: CGFloat = 38
    /// The history advances one column at this rate, so interpolating over
    /// exactly one column's worth of time turns a row of bars that restep
    /// fifteen times a second into one that flows. Linear because it is
    /// constant motion — an eased bar would pulse.
    private static let columnDuration: Double = 1.0 / 15.0

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            // Keyed by position, not by value: the levels slide across a fixed
            // row of bars, which is what gives each one something to animate
            // from. Keyed by value they would be new views every tick, and new
            // views can only pop.
            ForEach(Array(model.history.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(4, CGFloat(level) * Self.height))
                    .animation(.linear(duration: Self.columnDuration), value: level)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
