import XCTest

@testable import parrot

/// FluidAudio reports download progress per sub-operation — one reporter per
/// CoreML model — so the raw fraction restarts at 0 several times per fetch.
/// The Models pane has to read as one continuous operation regardless.
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

    /// The landing belongs to whoever knows the operation finished, so the
    /// curve must never hand the progress bar a full one on its own.
    func testNeverReachesOne() {
        var curve = WarmupProgressCurve()
        var mapped = 0.0
        for _ in 0..<20 {
            for raw in subOperation { mapped = curve.advance(to: raw) }
        }
        XCTAssertLessThan(mapped, 1)
    }

    /// Clamped rather than trusted: a reporter that overshoots would otherwise
    /// push the curve past the segment it was given and never recover.
    func testOutOfRangeInputStaysInsideTheSegment() {
        var curve = WarmupProgressCurve()
        XCTAssertEqual(curve.advance(to: 4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: -1), 0.5, accuracy: 1e-9)
    }

    /// An overshoot must not be *remembered*, only clamped on the way out.
    /// Stored raw, 4 makes the perfectly ordinary 1 that follows look like a
    /// regression, and the curve spends a whole segment on nothing — the bar
    /// jumps to 75% while the download is where it already was.
    func testAnOvershootDoesNotCostASegment() {
        var curve = WarmupProgressCurve()
        XCTAssertEqual(curve.advance(to: 4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.advance(to: 1), 0.5, accuracy: 1e-9)
    }
}
