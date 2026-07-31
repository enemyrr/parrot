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

    private func monitor(
        latch: Bool = true,
        tapMs: Int = 300,
        windowMs: Int = 300
    ) -> (HotkeyMonitor, Events) {
        var config = LatchConfig.default
        config.enabled = latch
        config.tapMs = tapMs
        config.windowMs = windowMs
        let m = HotkeyMonitor(mask: fn, config: config)
        let events = Events()
        m.onEvent = { events.append($0) }
        return (m, events)
    }

    final class Events {
        private(set) var recorded: [HotkeyMonitor.Event] = []
        func append(_ e: HotkeyMonitor.Event) { recorded.append(e) }
    }

    // MARK: - Event filtering (the power fix)

    func testKeyUpIsNotSubscribed() {
        // Every keystroke produces a keyUp we have no use for. Subscribing
        // would double the tap's traffic for nothing.
        let keyUp = CGEventMask(1 << CGEventType.keyUp.rawValue)
        XCTAssertEqual(HotkeyMonitor.eventMask & keyUp, 0)

        let flagsChanged = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        XCTAssertNotEqual(HotkeyMonitor.eventMask & flagsChanged, 0)
        XCTAssertNotEqual(HotkeyMonitor.eventMask & keyDown, 0)
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

}
