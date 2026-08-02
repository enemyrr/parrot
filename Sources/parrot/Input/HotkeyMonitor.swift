import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches the hotkeys (default: Fn to dictate, ⌃ to squawk) and turns key
/// edges into recording events.
///
/// Two ways to start either one:
///   - **Hold** the key — push-to-talk. `.begin` on press, `.end` on release.
///   - **Double-tap** it — hands-free. Recording continues until the next tap.
///
/// One tap serves every binding. A second `CGEventTap` would double the traffic
/// through the callback for every keystroke on the system, and the two keys
/// share a state machine anyway: only one recording can be live at a time, so
/// whichever key started it is the only one that can end it.
///
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event: Equatable {
        /// Start capturing, in this mode.
        case begin(DictationMode)
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

    /// One hotkey, pre-chewed into the two scalars the tap callback compares
    /// against. Doing this per event meant rebuilding `CGEventFlags` from the
    /// modifier set for every keystroke typed anywhere on the system.
    private struct Binding {
        let mode: DictationMode
        let hotkey: Hotkey
        /// Flags of a bare-modifier hotkey. Empty for a key-based one.
        let modifierMask: CGEventFlags
        /// Keycode of a key-based hotkey, as the tap reports it. Nil for a
        /// bare modifier, which is also what distinguishes the two shapes.
        let keyCode: Int64?

        init(mode: DictationMode, hotkey: Hotkey) {
            self.mode = mode
            self.hotkey = hotkey
            self.modifierMask = hotkey.isBareModifier ? hotkey.modifiers.cgFlags : []
            self.keyCode = hotkey.keyCode.map(Int64.init)
        }
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

    /// The union — one tap serves every binding, so it has to ask for anything
    /// any of them needs.
    static func eventMask(for hotkeys: [Hotkey]) -> CGEventMask {
        hotkeys.reduce(0) { $0 | eventMask(for: $1) }
    }

    var eventMask: CGEventMask { Self.eventMask(for: bindings.map(\.hotkey)) }

    private let bindings: [Binding]
    private let debug: Bool
    private let config: LatchSettings
    var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var state: State = .idle
    /// Physical key state, per binding. One flag no longer does: Fn and ⌃ can
    /// be held at the same time, and each needs its own edges tracked or the
    /// second one down would look like the first one released.
    private var pressed: Set<DictationMode> = []
    /// Which binding owns the session in flight. Only meaningful when `state`
    /// isn't `.idle`, and only that binding's key can end it.
    private var activeMode: DictationMode = .dictate
    /// Fires if no second tap arrives; resolves the ambiguous quick release.
    private var doubleTapTimer: DispatchSourceTimer?
    /// Backstop so a forgotten hands-free session doesn't record forever.
    private var maxDurationTimer: DispatchSourceTimer?

    private static let escapeKeyCode = Int64(KeyNames.escape)

    init(hotkeys: [(DictationMode, Hotkey)], config: LatchSettings = .default, debug: Bool = false) {
        self.bindings = hotkeys.map(Binding.init(mode:hotkey:))
        self.config = config
        self.debug = debug
    }

    convenience init(hotkey: Hotkey = .fn, config: LatchSettings = .default, debug: Bool = false) {
        self.init(hotkeys: [(.dictate, hotkey)], config: config, debug: debug)
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
        pressed = []
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
        switch type {
        case .keyDown:
            if keycode == Self.escapeKeyCode { return true }
            // While a bare modifier is held down, every keystroke matters —
            // it's what tells ⌃C apart from a squawk. Only while it is *held*,
            // so this costs nothing when idle and nothing hands-free.
            if abortsOnKeystroke { return true }
            // `!pressed` also swallows auto-repeat, which fires keyDown a dozen
            // times a second for as long as the key is held — exactly the case
            // push-to-talk puts it in.
            return bindings.contains { $0.keyCode == keycode && !pressed.contains($0.mode) }
        case .keyUp:
            return bindings.contains { $0.keyCode == keycode && pressed.contains($0.mode) }
        case .flagsChanged:
            // Only the edges of a bare modifier's own flag matter.
            return bindings.contains { binding in
                guard binding.keyCode == nil else { return false }
                return flags.contains(binding.modifierMask) != pressed.contains(binding.mode)
            }
        default:
            return false
        }
    }

    /// True while a push-to-talk hold is running on a bare modifier.
    ///
    /// A bare modifier is half of every shortcut on the Mac, which is the one
    /// real cost of using one as a hotkey — ⌃ especially. So a keystroke landing
    /// on top of a held modifier is read as the user reaching for ⌃C, not as
    /// speech, and throws the recording away. Deliberately not extended to the
    /// hands-free states: there the key is not held, the user is meant to keep
    /// working, and typing has nothing to do with the recording.
    private var abortsOnKeystroke: Bool {
        guard case .holding = state else { return false }
        return bindings.first { $0.mode == activeMode }?.keyCode == nil
    }

    func handle(type: CGEventType, flags: CGEventFlags, keycode: Int64) {
        if debug {
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }

        let isHotkeyKey = bindings.contains { $0.keyCode == keycode }

        if type == .keyDown, !isHotkeyKey {
            // Escape cancels — unless it *is* a hotkey, in which case pressing
            // it has to start a recording rather than throw one away.
            if keycode == Self.escapeKeyCode {
                handleEscape()
                return
            }
            // Anything else typed over a held modifier is a shortcut.
            if abortsOnKeystroke {
                finish(.cancelled)
                return
            }
        }

        switch type {
        case .flagsChanged:
            // Every bare binding re-reads the same flags: one event can move
            // two of them, and a press of the second must not be mistaken for
            // a release of the first.
            for binding in bindings where binding.keyCode == nil {
                setPressed(binding.mode, flags.contains(binding.modifierMask))
            }
        case .keyDown:
            guard let binding = bindings.first(where: { $0.keyCode == keycode }) else { return }
            // The modifiers have to be down *with* the key. Checked only on the
            // way down: releasing ⌃ before Space is a normal way to let go of
            // ⌃Space, and it must not strand a recording.
            guard HotkeyModifiers(cgFlags: flags).isSuperset(of: binding.hotkey.modifiers)
            else { return }
            setPressed(binding.mode, true)
        case .keyUp:
            guard let binding = bindings.first(where: { $0.keyCode == keycode }) else { return }
            setPressed(binding.mode, false)
        default:
            break
        }
    }

    private func setPressed(_ mode: DictationMode, _ isDown: Bool) {
        guard pressed.contains(mode) != isDown else { return }
        if isDown {
            pressed.insert(mode)
            handlePress(mode)
        } else {
            pressed.remove(mode)
            handleRelease(mode)
        }
    }

    // MARK: - State machine

    /// A press only matters if nothing is running, or if it belongs to the
    /// session that is. Reaching for the other key mid-recording does nothing
    /// at all — the alternative is switching modes on audio already captured
    /// under the first one.
    private func handlePress(_ mode: DictationMode) {
        switch state {
        case .idle:
            activeMode = mode
            state = .holding(since: Date())
            onEvent?(.begin(mode))

        case .latched where mode == activeMode:
            // Second tap of hands-free mode: stop and transcribe.
            finish(.end)

        case .awaitingSecondTap where mode == activeMode:
            // The tap we were waiting for. Already recording — just latch.
            cancelDoubleTapTimer()
            state = .latched
            armMaxDurationTimer()
            onEvent?(.latched)

        default:
            // The other mode's key during a live session, or a repeat that
            // `pressed` should already have deduped.
            break
        }
    }

    private func handleRelease(_ mode: DictationMode) {
        guard mode == activeMode, case .holding(let since) = state else {
            // The other mode's key, the key that stopped a hands-free
            // recording, or the second tap's release. Nothing to do.
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
