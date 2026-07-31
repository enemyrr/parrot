import FluidAudio
import XCTest

@testable import parrot

/// FluidAudio reports warm-up progress per sub-operation — one reporter per
/// CoreML model — so the raw fraction restarts at 0 several times per launch.
/// The pill has to read as one continuous operation regardless.
final class WarmupProgressCurveTests: XCTestCase {
    /// What a cached start emits, four times over: listing, the cached-models
    /// marker, a compile step, then done.
    private let subOperation = [0.0, 0.5, 0.75, 1.0]

    func testFoldsASawtoothIntoAMonotonicCurve() {
        var curve = WarmupProgressCurve()
        var last = -1.0
        for _ in 0..<4 {
            for raw in subOperation {
                let mapped = curve.advance(to: raw)
                XCTAssertGreaterThanOrEqual(mapped, last, "progress went backwards")
                last = mapped
            }
        }
    }

    func testEachSubOperationTakesHalfOfWhatIsLeft() {
        var curve = WarmupProgressCurve()
        XCTAssertEqual(curve.advance(to: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 1), 0.75, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 0), 0.75, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 1), 0.875, accuracy: 1e-9)
    }

    /// The landing belongs to `completeDownload()`, so the curve must never
    /// hand the ring a full circle on its own.
    func testNeverReachesOne() {
        var curve = WarmupProgressCurve()
        var mapped = 0.0
        for _ in 0..<20 {
            for raw in subOperation { mapped = curve.advance(to: raw) }
        }
        XCTAssertLessThan(mapped, 1)
    }
}

/// The startup pill is raised from a progress callback that hops to the main
/// actor and dismissed from the warm-up caller on the main thread, so the two
/// can arrive in either order. Getting that wrong strands the pill on screen
/// for the rest of the session — the "stuck downloading" bug.
@MainActor
final class WarmupHUDTests: XCTestCase {
    private func cachedProgress(_ fraction: Double) -> DownloadProgress {
        DownloadProgress(
            fractionCompleted: fraction,
            phase: .downloading(completedFiles: 0, totalFiles: 0)
        )
    }

    func testWarmUpTakesDownThePillItRaised() {
        let overlay = RecordingOverlay()
        let hud = WarmupHUD(overlay: overlay, modelID: "parakeet-v3")
        hud.report(cachedProgress(0.5))
        XCTAssertTrue(overlay.downloadPillShown)

        // `show()` defers its state change by a runloop turn, so completion
        // can't key off the overlay's published state to find its own pill.
        hud.finish()
        XCTAssertFalse(overlay.downloadPillShown)
    }

    func testProgressArrivingAfterWarmUpNeverRaisesThePill() {
        let overlay = RecordingOverlay()
        let hud = WarmupHUD(overlay: overlay, modelID: "parakeet-v3")
        // Warm-up returned before the main actor drained a single callback —
        // two launches out of three in the log this was found in.
        hud.finish()
        hud.report(cachedProgress(0.5))
        XCTAssertFalse(overlay.downloadPillShown, "a late callback stranded the pill")
    }
}
