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
    enum Event {
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

    /// Modifiers usable as the push-to-talk key.
    ///
    /// `CGEventFlags` carries no left/right distinction, so "option" means
    /// either option key. Telling them apart would mean tracking keycodes
    /// through `flagsChanged`, which isn't worth it for a hold-to-talk key.
    static func mask(forHotkey name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "fn", "function", "globe": return .maskSecondaryFn
        case "option", "alt", "left-option", "right-option": return .maskAlternate
        case "control", "ctrl": return .maskControl
        case "command", "cmd": return .maskCommand
        case "shift": return .maskShift
        default: return nil
        }
    }

    static let supportedHotkeys = "fn, option, control, command, shift"

    private enum State {
        case idle
        /// Key is physically down; `since` decides tap vs hold on release.
        case holding(since: Date)
        /// Released quickly — waiting to see if a second tap arrives.
        case awaitingSecondTap
        case latched
    }

    /// Mask of the modifier we treat as the hotkey. Fn = `.maskSecondaryFn`.
    private let mask: CGEventFlags
    private let debug: Bool
    private let config: LatchConfig
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var state: State = .idle
    private var isPressed = false
    /// Fires if no second tap arrives; resolves the ambiguous quick release.
    private var doubleTapTimer: DispatchSourceTimer?
    /// Backstop so a forgotten hands-free session doesn't record forever.
    private var maxDurationTimer: DispatchSourceTimer?

    private static let escapeKeyCode: Int64 = 53

    init(mask: CGEventFlags = .maskSecondaryFn, config: LatchConfig = .default, debug: Bool = false) {
        self.mask = mask
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

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
            handleEscape()
            return
        }

        guard type == .flagsChanged else { return }
        let pressed = event.flags.contains(mask)
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
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
