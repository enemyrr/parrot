import CoreGraphics
import XCTest

@testable import parrot

/// The state machine and, crucially, the filter that decides whether an event
/// is worth waking the main thread for. The tap sees every keystroke typed
/// anywhere on the system, so `wants` is the hottest code in the daemon.
final class HotkeyMonitorTests: XCTestCase {
    private let fn = CGEventFlags.maskSecondaryFn
    private let escape: Int64 = 53
    private let letterA: Int64 = 0

    /// ⌃⌥Space, the shape a recorded shortcut takes.
    private let combo = Hotkey(
        keyCode: 49, modifiers: [.control, .option], keyLabel: "Space"
    )
    private let space: Int64 = 49
    private let comboFlags: CGEventFlags = [.maskControl, .maskAlternate]

    private func monitor(
        hotkey: Hotkey = .fn,
        latch: Bool = true,
        tapMs: Int = 300,
        windowMs: Int = 300
    ) -> (HotkeyMonitor, Events) {
        var settings = LatchSettings.default
        settings.enabled = latch
        settings.tapMs = tapMs
        settings.windowMs = windowMs
        let m = HotkeyMonitor(hotkey: hotkey, config: settings)
        let events = Events()
        m.onEvent = { events.append($0) }
        return (m, events)
    }

    final class Events {
        private(set) var recorded: [HotkeyMonitor.Event] = []
        func append(_ e: HotkeyMonitor.Event) { recorded.append(e) }
    }

    // MARK: - Event filtering (the power fix)

    private let keyUpMask = CGEventMask(1 << CGEventType.keyUp.rawValue)

    func testKeyUpIsNotSubscribedForABareModifier() {
        // Every keystroke produces a keyUp we have no use for. Subscribing
        // would double the tap's traffic for nothing.
        let mask = HotkeyMonitor.eventMask(for: .fn)
        XCTAssertEqual(mask & keyUpMask, 0)

        let flagsChanged = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        XCTAssertNotEqual(mask & flagsChanged, 0)
        XCTAssertNotEqual(mask & keyDown, 0)
    }

    /// A key-based hotkey has no other way to see the release, so there the
    /// extra traffic is the price of the feature rather than waste.
    func testKeyUpIsSubscribedForAKeyShortcut() {
        XCTAssertNotEqual(HotkeyMonitor.eventMask(for: combo) & keyUpMask, 0)
    }

    func testOrdinaryTypingIsFilteredOut() {
        let (m, _) = monitor()
        XCTAssertFalse(m.wants(type: .keyDown, flags: [], keycode: letterA))
    }

    func testUnrelatedModifiersAreFilteredOut() {
        let (m, _) = monitor()
        // Shift fires flagsChanged on every capital letter typed system-wide.
        XCTAssertFalse(m.wants(type: .flagsChanged, flags: .maskShift, keycode: 0))
        XCTAssertFalse(m.wants(type: .flagsChanged, flags: .maskCommand, keycode: 0))
    }

    func testHotkeyEdgesAreForwarded() {
        let (m, _) = monitor()
        XCTAssertTrue(m.wants(type: .flagsChanged, flags: fn, keycode: 0))
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        // Now held: a repeat of the same state is no longer interesting...
        XCTAssertFalse(m.wants(type: .flagsChanged, flags: fn, keycode: 0))
        // ...but the release is.
        XCTAssertTrue(m.wants(type: .flagsChanged, flags: [], keycode: 0))
    }

    func testHotkeyCombinedWithOtherModifiersStillForwards() {
        let (m, _) = monitor()
        XCTAssertTrue(m.wants(type: .flagsChanged, flags: [fn, .maskShift], keycode: 0))
    }

    func testEscapeIsForwarded() {
        let (m, _) = monitor()
        XCTAssertTrue(m.wants(type: .keyDown, flags: [], keycode: escape))
    }

    // MARK: - State machine

    func testHoldProducesBeginThenEnd() {
        let (m, events) = monitor()
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        XCTAssertEqual(events.recorded.count, 1)
        XCTAssertEqual(events.recorded[0], .begin)

        // A hold longer than tapMs ends immediately on release.
        Thread.sleep(forTimeInterval: 0.35)
        m.handle(type: .flagsChanged, flags: [], keycode: 0)
        XCTAssertEqual(events.recorded.count, 2)
        XCTAssertEqual(events.recorded[1], .end)
    }

    func testDoubleTapLatches() {
        let (m, events) = monitor()
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)   // press 1
        m.handle(type: .flagsChanged, flags: [], keycode: 0)   // quick release
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)   // press 2

        XCTAssertEqual(events.recorded[0], .begin)
        XCTAssertEqual(events.recorded[1], .latched)

        // A third press stops and transcribes.
        m.handle(type: .flagsChanged, flags: [], keycode: 0)
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        XCTAssertEqual(events.recorded[2], .end)
    }

    func testShortTapWithoutSecondTapEndsAfterWindow() {
        let (m, events) = monitor(windowMs: 60)
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        m.handle(type: .flagsChanged, flags: [], keycode: 0)
        XCTAssertEqual(events.recorded[0], .begin)
        XCTAssertEqual(events.recorded.count, 1, "should wait out the double-tap window")

        let ended = expectation(description: "end after window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ended.fulfill() }
        wait(for: [ended], timeout: 1)

        XCTAssertEqual(events.recorded.count, 2)
        XCTAssertEqual(events.recorded[1], .end)
    }

    func testLatchDisabledEndsOnEveryRelease() {
        let (m, events) = monitor(latch: false)
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        m.handle(type: .flagsChanged, flags: [], keycode: 0)
        XCTAssertEqual(events.recorded.count, 2)
        XCTAssertEqual(events.recorded[1], .end)
    }

    func testEscapeCancelsWhileRecording() {
        let (m, events) = monitor()
        m.handle(type: .flagsChanged, flags: fn, keycode: 0)
        m.handle(type: .keyDown, flags: [], keycode: escape)
        XCTAssertEqual(events.recorded[1], .cancelled)
    }

    func testEscapeWhileIdleDoesNothing() {
        let (m, events) = monitor()
        m.handle(type: .keyDown, flags: [], keycode: escape)
        XCTAssertTrue(events.recorded.isEmpty)
    }

    // MARK: - Custom key shortcuts

    func testKeyShortcutProducesBeginThenEnd() {
        let (m, events) = monitor(hotkey: combo)
        m.handle(type: .keyDown, flags: comboFlags, keycode: space)
        XCTAssertEqual(events.recorded, [.begin])

        Thread.sleep(forTimeInterval: 0.35)
        m.handle(type: .keyUp, flags: comboFlags, keycode: space)
        XCTAssertEqual(events.recorded, [.begin, .end])
    }

    func testKeyShortcutIgnoresTheKeyWithoutItsModifiers() {
        let (m, events) = monitor(hotkey: combo)
        // Space on its own is a space, not a dictation.
        XCTAssertFalse(m.wants(type: .keyDown, flags: [], keycode: letterA))
        m.handle(type: .keyDown, flags: [], keycode: space)
        XCTAssertTrue(events.recorded.isEmpty)

        // Extra modifiers on top are fine — ⌃⌥⇧Space still contains ⌃⌥Space.
        m.handle(type: .keyDown, flags: [.maskControl, .maskAlternate, .maskShift], keycode: space)
        XCTAssertEqual(events.recorded, [.begin])
    }

    /// Auto-repeat fires keyDown a dozen times a second for as long as the key
    /// is held — exactly what push-to-talk does to it.
    func testKeyShortcutFiltersAutoRepeat() {
        let (m, events) = monitor(hotkey: combo)
        XCTAssertTrue(m.wants(type: .keyDown, flags: comboFlags, keycode: space))
        m.handle(type: .keyDown, flags: comboFlags, keycode: space)
        XCTAssertFalse(m.wants(type: .keyDown, flags: comboFlags, keycode: space))
        XCTAssertEqual(events.recorded, [.begin])
    }

    /// Letting go of ⌃ before Space is a normal way to release ⌃Space, and it
    /// must not strand a recording that can only be ended by the key.
    func testKeyShortcutReleaseIgnoresModifiers() {
        let (m, events) = monitor(hotkey: combo)
        m.handle(type: .keyDown, flags: comboFlags, keycode: space)
        Thread.sleep(forTimeInterval: 0.35)
        m.handle(type: .keyUp, flags: [], keycode: space)
        XCTAssertEqual(events.recorded, [.begin, .end])
    }

    func testKeyShortcutStillLatchesOnADoubleTap() {
        let (m, events) = monitor(hotkey: combo)
        m.handle(type: .keyDown, flags: comboFlags, keycode: space)
        m.handle(type: .keyUp, flags: comboFlags, keycode: space)
        m.handle(type: .keyDown, flags: comboFlags, keycode: space)
        XCTAssertEqual(events.recorded, [.begin, .latched])
    }

    /// Escape normally cancels. When it *is* the hotkey, pressing it has to
    /// start a recording instead.
    func testEscapeAsTheHotkeyRecordsRatherThanCancels() {
        let escapeHotkey = Hotkey(keyCode: 53, modifiers: [.control], keyLabel: "Esc")
        let (m, events) = monitor(hotkey: escapeHotkey)
        m.handle(type: .keyDown, flags: .maskControl, keycode: escape)
        XCTAssertEqual(events.recorded, [.begin])
    }

    // MARK: - Validity

    func testUsabilityRules() {
        XCTAssertTrue(Hotkey.fn.isUsable)
        XCTAssertTrue(combo.isUsable)
        // Two bare modifiers have no single flag to watch.
        XCTAssertFalse(Hotkey(modifiers: [.control, .option]).isUsable)
        XCTAssertFalse(Hotkey(modifiers: []).isUsable)
        // A bare letter would type itself while you talk.
        XCTAssertFalse(Hotkey(keyCode: 0, modifiers: [], keyLabel: "A").isUsable)
        // A function key types nothing, so it needs no modifier. F13 = 105.
        XCTAssertTrue(Hotkey(keyCode: 105, modifiers: [], keyLabel: "F13").isUsable)
    }

    func testDisplayLabels() {
        XCTAssertEqual(Hotkey.fn.displayName, "Fn")
        XCTAssertEqual(combo.displayLabel, "⌃⌥Space")
        // Apple's printed order, whatever order the flags arrived in.
        XCTAssertEqual(
            Hotkey(keyCode: 49, modifiers: [.command, .shift, .fn], keyLabel: "Space").displayLabel,
            "🌐⇧⌘Space"
        )
    }
}
