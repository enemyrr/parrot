import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: Fn) and turns key edges into
/// dictation events.
///
/// Two ways to dictate:
///   - **Hold** the key — push-to-talk. `.begin` on press, `.end` on release.
///   - **Double-tap** it — hands-free. Recording continues until the next tap.
///
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event: Equatable {
        /// Start capturing.
        case begin
        /// Still capturing, now hands-free — no need to keep holding.
        case latched
        /// Stop capturing and transcribe.
        case end
        /// Stop capturing and throw the audio away.
        case cancelled
    }

    enum HotkeyError: Error {
        /// Accessibility permission is missing — a human has to fix this, so
        /// callers should stop rather than retry.
        case accessibilityDenied
        case tapCreateFailed
    }

    private enum State {
        case idle
        /// Key is physically down; `since` decides tap vs hold on release.
        case holding(since: Date)
        /// Released quickly — waiting to see if a second tap arrives.
        case awaitingSecondTap
        case latched
    }

    /// Events we ask the tap for.
    ///
    /// For a bare-modifier hotkey, `keyUp` is deliberately absent: the only
    /// non-modifier key we care about is Escape, and one edge is enough to
    /// cancel. Subscribing to it would double the number of events the tap
    /// hands us — for every keystroke the user ever types, in any app — to no
    /// purpose. A key-based hotkey has no other way to see the release, so
    /// there it is the price of the feature rather than waste.
    static func eventMask(for hotkey: Hotkey) -> CGEventMask {
        var mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        if !hotkey.isBareModifier {
            mask |= (1 << CGEventType.keyUp.rawValue)
        }
        return mask
    }

    var eventMask: CGEventMask { Self.eventMask(for: hotkey) }

    private let hotkey: Hotkey
    /// Flags of a bare-modifier hotkey. Empty for a key-based one.
    private let modifierMask: CGEventFlags
    /// Keycode of a key-based hotkey, as the tap reports it.
    private let hotkeyCode: Int64?
    private let debug: Bool
    private let config: LatchSettings
    var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var state: State = .idle
    private var isPressed = false
    /// Fires if no second tap arrives; resolves the ambiguous quick release.
    private var doubleTapTimer: DispatchSourceTimer?
    /// Backstop so a forgotten hands-free session doesn't record forever.
    private var maxDurationTimer: DispatchSourceTimer?

    private static let escapeKeyCode = Int64(KeyNames.escape)

    init(hotkey: Hotkey = .fn, config: LatchSettings = .default, debug: Bool = false) {
        self.hotkey = hotkey
        self.modifierMask = hotkey.isBareModifier ? hotkey.modifiers.cgFlags : []
        self.hotkeyCode = hotkey.keyCode.map(Int64.init)
        self.config = config
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            throw HotkeyError.accessibilityDenied
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        // A session in flight has to be told it's over. The caller stops
        // listening here — changing the hotkey in settings restarts the
        // monitor — and without a terminal event the microphone stays open
        // with nothing left that could ever close it.
        if case .idle = state {} else {
            onEvent?(.cancelled)
        }
        cancelDoubleTapTimer()
        cancelMaxDurationTimer()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
        state = .idle
        isPressed = false
    }

    /// The system disables a tap whose callback was too slow, or that it saw
    /// the user fight with. It stays disabled until asked otherwise, so without
    /// this the hotkey is dead for the rest of the process's life.
    fileprivate func reenableTap() {
        guard let tap else { return }
        FileHandle.standardError.write(Data("hotkey tap was disabled — re-enabling\n".utf8))
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Whether an event is worth handing to the state machine.
    ///
    /// Checked in the tap callback so the overwhelming majority of events —
    /// every ordinary keystroke, and every modifier press that isn't our
    /// hotkey — cost one comparison instead of a `CGEvent` copy and a
    /// main-queue dispatch. Shift alone makes `.flagsChanged` fire on every
    /// capital letter typed anywhere on the system.
    func wants(type: CGEventType, flags: CGEventFlags, keycode: Int64) -> Bool {
        if debug { return true }
        guard let hotkeyCode else {
            // Bare modifier: only the edges of that one flag matter.
            switch type {
            case .keyDown: return keycode == Self.escapeKeyCode
            case .flagsChanged: return flags.contains(modifierMask) != isPressed
            default: return false
            }
        }
        switch type {
        // `!isPressed` also swallows auto-repeat, which fires keyDown a dozen
        // times a second for as long as the key is held — exactly the case
        // push-to-talk puts it in.
        case .keyDown:
            return keycode == Self.escapeKeyCode || (keycode == hotkeyCode && !isPressed)
        case .keyUp:
            return keycode == hotkeyCode && isPressed
        default:
            return false
        }
    }

    func handle(type: CGEventType, flags: CGEventFlags, keycode: Int64) {
        if debug {
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }

        // Escape cancels — unless it *is* the hotkey, in which case pressing it
        // has to start a recording rather than throw one away.
        if type == .keyDown, keycode == Self.escapeKeyCode, keycode != hotkeyCode {
            handleEscape()
            return
        }

        guard let hotkeyCode else {
            guard type == .flagsChanged else { return }
            setPressed(flags.contains(modifierMask))
            return
        }

        guard keycode == hotkeyCode else { return }
        switch type {
        case .keyDown:
            // The modifiers have to be down *with* the key. Checked only on the
            // way down: releasing ⌃ before Space is a normal way to let go of
            // ⌃Space, and it must not strand a recording.
            guard HotkeyModifiers(cgFlags: flags).isSuperset(of: hotkey.modifiers) else { return }
            setPressed(true)
        case .keyUp:
            setPressed(false)
        default:
            break
        }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        if pressed { handlePress() } else { handleRelease() }
    }

    // MARK: - State machine

    private func handlePress() {
        switch state {
        case .latched:
            // Second tap of hands-free mode: stop and transcribe.
            finish(.end)

        case .awaitingSecondTap:
            // The tap we were waiting for. Already recording — just latch.
            cancelDoubleTapTimer()
            state = .latched
            armMaxDurationTimer()
            onEvent?(.latched)

        case .idle:
            state = .holding(since: Date())
            onEvent?(.begin)

        case .holding:
            // Shouldn't happen — `isPressed` dedupes repeats.
            break
        }
    }

    private func handleRelease() {
        guard case .holding(let since) = state else {
            // Releasing the key that stopped a hands-free recording, or the
            // second tap's release. Nothing to do either way.
            return
        }

        let heldMs = Date().timeIntervalSince(since) * 1000
        let wasATap = config.enabled && heldMs < Double(config.tapMs)

        guard wasATap else {
            // A real hold. End immediately — the push-to-talk path keeps its
            // original zero added latency.
            finish(.end)
            return
        }

        // Too short to be speech. Wait out the double-tap window before
        // committing, so a second tap can promote this into hands-free mode.
        state = .awaitingSecondTap
        startDoubleTapTimer()
    }

    private func handleEscape() {
        switch state {
        case .idle:
            break
        case .holding, .awaitingSecondTap, .latched:
            finish(.cancelled)
        }
    }

    private func finish(_ event: Event) {
        cancelDoubleTapTimer()
        cancelMaxDurationTimer()
        state = .idle
        onEvent?(event)
    }

    // MARK: - Timers

    private func startDoubleTapTimer() {
        cancelDoubleTapTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(config.windowMs))
        timer.setEventHandler { [weak self] in
            guard let self, case .awaitingSecondTap = self.state else { return }
            // No second tap — it was just a short press after all.
            self.finish(.end)
        }
        timer.resume()
        doubleTapTimer = timer
    }

    private func cancelDoubleTapTimer() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
    }

    private func armMaxDurationTimer() {
        cancelMaxDurationTimer()
        guard config.maxSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(config.maxSeconds))
        timer.setEventHandler { [weak self] in
            guard let self, case .latched = self.state else { return }
            FileHandle.standardError.write(Data(
                "hands-free recording hit the \(self.config.maxSeconds)s cap — stopping\n".utf8
            ))
            self.finish(.end)
        }
        timer.resume()
        maxDurationTimer = timer
    }

    private func cancelMaxDurationTimer() {
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Re-enabling has to happen off the callback — the tap is mid-teardown
        // here — and the source lives on the main runloop either way.
        DispatchQueue.main.async { monitor.reenableTap() }
        return Unmanaged.passUnretained(event)
    }

    // Pull out the three scalars the state machine needs rather than
    // `event.copy()` — that allocated a CGEvent for every keystroke on the
    // system, only to throw nearly all of them away.
    let flags = event.flags
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    guard monitor.wants(type: type, flags: flags, keycode: keycode) else {
        return Unmanaged.passUnretained(event)
    }

    // The tap source lives on the main runloop, so this callback already runs
    // on main. The hop still earns its keep: `.end` synchronously stops the
    // audio engine, and a slow tap callback gets the tap disabled by the
    // system. Deferring a runloop turn keeps that work outside the callback.
    DispatchQueue.main.async {
        monitor.handle(type: type, flags: flags, keycode: keycode)
    }
    return Unmanaged.passUnretained(event)
}
