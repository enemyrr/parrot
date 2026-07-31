import AVFoundation
import XCTest

@testable import parrot

/// `computeRMS` moved from a scalar loop to vDSP because it runs over the whole
/// capture when a recording ends — 4.8M samples for a five-minute hands-free
/// session. These tests pin the numeric result against the original definition.
final class AudioCaptureTests: XCTestCase {
    /// The implementation this replaced, kept as the oracle.
    private func referenceRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s * s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    func testRMSOfEmptyIsZero() {
        XCTAssertEqual(computeRMS([]), 0)
    }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(computeRMS([Float](repeating: 0, count: 1024)), 0)
    }

    func testRMSOfConstantSignalIsItsMagnitude() {
        XCTAssertEqual(computeRMS([Float](repeating: 0.5, count: 512)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(computeRMS([Float](repeating: -0.5, count: 512)), 0.5, accuracy: 1e-6)
    }

    func testRMSOfFullScaleSineIsOneOverRootTwo() {
        let samples = (0..<16_000).map { sinf(2 * .pi * 440 * Float($0) / 16_000) }
        XCTAssertEqual(computeRMS(samples), Float(1 / 2.0.squareRoot()), accuracy: 1e-3)
    }

    func testRMSMatchesTheScalarImplementation() {
        var generator = SystemRandomNumberGenerator()
        for count in [1, 7, 64, 4096, 100_000] {
            let samples = (0..<count).map { _ in Float.random(in: -1...1, using: &generator) }
            XCTAssertEqual(
                computeRMS(samples),
                referenceRMS(samples),
                accuracy: 1e-5,
                "mismatch at count \(count)"
            )
        }
    }

    // MARK: - Conversion path
    //
    // The tap callback reuses one output buffer and one converter across the
    // whole recording. That's where a stale-frameLength or stale-samples bug
    // would live, so drive it directly with synthesized input — no microphone
    // required.

    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    /// A mono 48 kHz buffer of `frames` samples at constant `amplitude`.
    private func buffer(frames: AVAudioFrameCount, amplitude: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        b.frameLength = frames
        let ptr = b.floatChannelData![0]
        for i in 0..<Int(frames) { ptr[i] = amplitude }
        return b
    }

    private func newConverter() -> AVAudioConverter {
        AVAudioConverter(from: inputFormat, to: AudioCapture.targetFormat)!
    }

    /// The pre-optimisation implementation: a fresh output buffer every call
    /// and an intermediate `Array` copy. Used as an oracle — the point of the
    /// change was that it's *only* an allocation change, so the sample stream
    /// must come out bit-for-bit identical.
    private func referenceProcess(
        buffers: [AVAudioPCMBuffer],
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        var samples: [Float] = []
        for buffer in buffers {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
            else { continue }

            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, s in
                if consumed { s.pointee = .noDataNow; return nil }
                consumed = true
                s.pointee = .haveData
                return buffer
            }
            guard status != .error, let ch = out.floatChannelData else { continue }
            samples.append(contentsOf: Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
        return samples
    }

    private func assertMatchesReference(
        _ shapes: [(frames: AVAudioFrameCount, amplitude: Float)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capture = AudioCapture()
        let converter = newConverter()
        for shape in shapes {
            capture.process(
                buffer: buffer(frames: shape.frames, amplitude: shape.amplitude),
                converter: converter,
                targetFormat: AudioCapture.targetFormat
            )
        }
        let expected = referenceProcess(
            buffers: shapes.map { buffer(frames: $0.frames, amplitude: $0.amplitude) },
            converter: newConverter(),
            targetFormat: AudioCapture.targetFormat
        )
        XCTAssertFalse(expected.isEmpty, "oracle produced nothing — test is vacuous", file: file, line: line)
        XCTAssertEqual(capture.captured, expected, file: file, line: line)
    }

    func testConversionMatchesReferenceForASingleBuffer() {
        assertMatchesReference([(4800, 0.5)])
    }

    func testConversionMatchesReferenceAcrossManyBuffers() {
        assertMatchesReference(Array(repeating: (AVAudioFrameCount(4800), Float(0.5)), count: 8))
    }

    /// Shrinking input is the case the reused buffer could get wrong: a short
    /// buffer after a long one must not carry the long one's `frameLength`.
    func testConversionMatchesReferenceWhenBufferSizesShrink() {
        assertMatchesReference([(19_200, 1.0), (480, 0.0), (4800, 0.25)])
    }

    /// Growing input forces the reused buffer to be reallocated mid-recording.
    func testConversionMatchesReferenceWhenBufferSizesGrow() {
        assertMatchesReference([(480, 0.25), (4800, 0.25), (19_200, 0.25)])
    }

    func testConversionDownsamplesToTargetRate() {
        let capture = AudioCapture()
        let converter = newConverter()
        // 48 kHz -> 16 kHz is 3:1. The first buffer loses a little to the
        // resampler's warm-up, so allow for it rather than pinning an exact count.
        for _ in 0..<4 {
            capture.process(
                buffer: buffer(frames: 4800, amplitude: 0.5),
                converter: converter,
                targetFormat: AudioCapture.targetFormat
            )
        }
        XCTAssertEqual(Double(capture.captured.count), 6400, accuracy: 320)
    }

    func testSuccessiveBuffersOnlyGrowTheCapture() {
        let capture = AudioCapture()
        let converter = newConverter()
        var previous = 0
        for _ in 0..<5 {
            capture.process(
                buffer: buffer(frames: 4800, amplitude: 0.5),
                converter: converter,
                targetFormat: AudioCapture.targetFormat
            )
            let count = capture.captured.count
            XCTAssertGreaterThan(count, previous)
            previous = count
        }
    }

    func testLevelCallbackFiresOncePerBufferAndTracksLoudness() {
        let capture = AudioCapture()
        let converter = newConverter()
        var levels: [Float] = []
        capture.onLevel = { levels.append($0) }
        let target = AudioCapture.targetFormat

        capture.process(buffer: buffer(frames: 4800, amplitude: 0.5), converter: converter, targetFormat: target)
        capture.process(buffer: buffer(frames: 4800, amplitude: 0.0), converter: converter, targetFormat: target)
        capture.process(buffer: buffer(frames: 4800, amplitude: 0.0), converter: converter, targetFormat: target)

        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels[0], 0.5, accuracy: 0.06)
        // The resampler's filter delay means silence doesn't land instantly —
        // the level falls off over a buffer or so rather than dropping to zero.
        XCTAssertLessThan(levels[1], levels[0])
        XCTAssertLessThan(levels[2], 0.01)
    }

    // MARK: - Capture lifecycle

    func testStopWithoutStartReturnsEmpty() {
        XCTAssertTrue(AudioCapture().stop().isEmpty)
    }

    /// The memory fix. A long hands-free session must not leave the daemon
    /// holding a capture-sized buffer forever: `removeAll(keepingCapacity:)`
    /// would copy-on-write an empty array at the *old* capacity, because the
    /// array just handed to the caller still references the storage.
    func testDrainReleasesLargeCaptureCapacity() {
        let capture = AudioCapture()
        let converter = newConverter()
        // ~24s of 48 kHz audio, well past the 30s baseline once accumulated.
        for _ in 0..<120 {
            capture.process(
                buffer: buffer(frames: 9600, amplitude: 0.3),
                converter: converter,
                targetFormat: AudioCapture.targetFormat
            )
        }
        let grown = capture.captured.capacity
        XCTAssertGreaterThan(grown, AudioCapture.baselineCapacity)

        let captured = capture.drain()
        XCTAssertFalse(captured.isEmpty, "drain must hand back the audio")
        XCTAssertLessThan(
            capture.captured.capacity, grown,
            "capture buffer still pinned at the recording's peak size"
        )
        // `reserveCapacity` rounds up to a growth-friendly size, so pin a bound
        // rather than the exact figure.
        XCTAssertLessThan(capture.captured.capacity, AudioCapture.baselineCapacity * 2)
    }

    func testDrainLeavesTheBufferEmpty() {
        let capture = AudioCapture()
        let converter = newConverter()
        capture.process(
            buffer: buffer(frames: 4800, amplitude: 0.5),
            converter: converter,
            targetFormat: AudioCapture.targetFormat
        )
        XCTAssertFalse(capture.drain().isEmpty)
        XCTAssertTrue(capture.captured.isEmpty)
        XCTAssertTrue(capture.drain().isEmpty)
    }

    func testTargetFormatIs16kMono() {
        XCTAssertEqual(AudioCapture.targetFormat.sampleRate, 16_000)
        XCTAssertEqual(AudioCapture.targetFormat.channelCount, 1)
        XCTAssertEqual(AudioCapture.targetFormat.commonFormat, .pcmFormatFloat32)
    }

    // MARK: - WAV writer

    func testWAVWriterProducesAReadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = (0..<1000).map { sinf(2 * .pi * 440 * Float($0) / 16_000) }
        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: url.path)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 1000)
    }

    func testWAVWriterClampsOutOfRangeSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Without clamping, 2.0 overflows Int16 and traps.
        try WAVWriter.write(samples: [2.0, -2.0, 0.0], sampleRate: 16_000, to: url.path)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 6)
    }
}
