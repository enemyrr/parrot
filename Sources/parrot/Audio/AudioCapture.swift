import Accelerate
import AVFoundation
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
    }

    static let targetSampleRate: Double = 16_000

    /// Samples to keep room for between recordings — 30s at 16 kHz, ~1.9 MB.
    /// Long enough that a typical dictation never reallocates, small enough
    /// that a one-off five-minute hands-free session doesn't pin 19 MB for the
    /// rest of the daemon's life.
    static let baselineCapacity = Int(targetSampleRate) * 30

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRecording = false
    private let lock = NSLock()

    /// Built on first use and kept for the life of the daemon — creating one
    /// per recording added startup latency to every hotkey press. Rebuilt only
    /// if the input device changes format under us.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// Reused across tap callbacks; the tap is serialized, so one is enough.
    private var outBuffer: AVAudioPCMBuffer?

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    /// CoreAudio UID of the microphone to record from. Empty or nil means the
    /// system default. Read at `start()`, so changing it takes effect on the
    /// next recording rather than mid-utterance.
    var preferredDeviceUID: String?

    /// Snapshot of what's accumulated so far, without ending the recording.
    /// Exists for tests; `stop()` is what callers want.
    var captured: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        // Before the format is read: switching device changes the node's sample
        // rate and channel count, and a tap installed with the old format would
        // be rejected the moment the engine starts.
        selectDevice(on: input)
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = Self.targetFormat
        let converter = try cachedConverter(for: inputFormat)

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Self.baselineCapacity)
        lock.unlock()

        // Tap with input format; convert inside the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
    }

    /// Point the engine's input at the chosen microphone.
    ///
    /// Resolved on every start rather than cached: the device may have been
    /// unplugged since it was picked, and falling back to the system default is
    /// a far better answer than refusing to record. Never fatal for the same
    /// reason — a device that won't take is worth a line in the log, not a lost
    /// dictation.
    private func selectDevice(on input: AVAudioInputNode) {
        let uid = preferredDeviceUID ?? ""
        let target = AudioDevices.device(uid: uid) ?? AudioDevices.systemDefaultInput()
        guard let target, input.auAudioUnit.deviceID != target.deviceID else { return }
        do {
            try input.auAudioUnit.setDeviceID(target.deviceID)
        } catch {
            FileHandle.standardError.write(Data(
                "could not record from \(target.name): \(error)\n".utf8
            ))
        }
    }

    private func cachedConverter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, let converterInputFormat, converterInputFormat == inputFormat {
            // Stale decoder state from the previous utterance would otherwise
            // bleed a few samples into the next one.
            converter.reset()
            return converter
        }
        guard let fresh = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        converter = fresh
        converterInputFormat = inputFormat
        return fresh
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false

        return drain()
    }

    /// Hand back everything captured and reset the buffer to its baseline.
    ///
    /// Deliberately *not* `removeAll(keepingCapacity:)`. The returned array
    /// still references the storage, so that would copy-on-write a fresh empty
    /// buffer at the same capacity — after a five-minute hands-free session the
    /// daemon would hold 19 MB of empty array for the rest of its life.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        samples.reserveCapacity(Self.baselineCapacity)
        return captured
    }

    /// Internal rather than private so tests can drive the conversion path
    /// with a synthesized buffer — it needs no microphone, and it's where the
    /// reused output buffer and cached converter would go wrong.
    func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        // Reuse across callbacks; only reallocate if the input grows. The tap
        // is serialized, so there's no second writer to race with.
        let outBuffer: AVAudioPCMBuffer
        if let existing = self.outBuffer, existing.frameCapacity >= outCapacity {
            outBuffer = existing
        } else {
            guard let fresh = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outCapacity
            ) else { return }
            self.outBuffer = fresh
            outBuffer = fresh
        }
        outBuffer.frameLength = 0

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channelData[0], count: count)

        // Append straight from the pointer — the intermediate `Array(...)` copy
        // this used to make was pure overhead on every audio callback.
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(rms(chunk))
        }
    }
}

// MARK: - WAV writer

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        try data(samples: samples, sampleRate: sampleRate)
            .write(to: URL(fileURLWithPath: path))
    }

    /// The same bytes without touching the disk — what an upload wants, and
    /// what `--dump-wav` writes out.
    static func data(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

/// Root-mean-square level of a sample block.
///
/// vDSP rather than a scalar loop: this runs over the *whole* capture when a
/// recording ends, and a five-minute hands-free session is 4.8M samples —
/// enough of a scalar loop to be felt as a hitch on the main thread at exactly
/// the moment the user is waiting for their text.
func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard let base = samples.baseAddress, samples.count > 0 else { return 0 }
    var result: Float = 0
    vDSP_rmsqv(base, 1, &result, vDSP_Length(samples.count))
    return result
}

func computeRMS(_ samples: [Float]) -> Float {
    samples.withUnsafeBufferPointer { rms($0) }
}
