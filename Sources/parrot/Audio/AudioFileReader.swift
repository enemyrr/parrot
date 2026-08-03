import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns a file on disk into the same 16 kHz mono Float32 the microphone
/// produces, so everything downstream of `AudioCapture` can't tell the
/// difference.
///
/// `AVAssetReader` rather than `AVAudioFile`: the second one opens audio files
/// only, and the recordings people actually want transcribed include the screen
/// recording and the exported Zoom call. Reading through an asset gets every
/// container AVFoundation knows — mp3, m4a, wav, aiff, caf, flac — and the audio
/// track out of a video for free, on one code path.
enum AudioFileReader {
    enum ReadError: Error, CustomStringConvertible {
        case missingFile(String)
        case unreadable(String)
        case noAudioTrack
        case empty

        var description: String {
            switch self {
            case .missingFile(let path): return "no file at \(path)"
            case .unreadable(let why): return "couldn't read that file: \(why)"
            case .noAudioTrack: return "that file has no audio track"
            case .empty: return "that file has no audio in it"
            }
        }
    }

    /// What the open panel and the drop zone accept. Deliberately the two broad
    /// families rather than a list of extensions — AVFoundation's reach changes
    /// between OS releases, and a hardcoded list would refuse files the decoder
    /// underneath would have handled.
    static let contentTypes: [UTType] = [.audio, .movie]

    /// Whether `AVAudioFile` can open this directly, which is the question
    /// `ParakeetTranscriber` asks before handing the URL to FluidAudio's
    /// disk-backed path. False for a video container, whose audio has to be
    /// demuxed first.
    static func isPlainAudioFile(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }

    /// Seconds of audio, or nil if the file can't be read at all. Used to size
    /// the buffer and to say "12:41" before any work starts.
    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Decode the whole file into memory.
    ///
    /// At 16 kHz mono float that is 3.8 MB per minute, so an hour-long meeting
    /// costs about 230 MB while it is being transcribed. The local engine avoids
    /// paying it — see `ParakeetTranscriber.transcribe(fileAt:)`, which streams
    /// the same file off disk instead — so this is the path for the API model
    /// and for video containers, both of which are bounded by other things
    /// first.
    static func samples(at url: URL) async throws -> [Float] {
        // The whole read happens inside the detached task, asset included: an
        // AVAsset is not Sendable, and the decode loop is a few hundred
        // milliseconds of tight work that has no business on the main actor.
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ReadError.missingFile(url.path)
            }

            let asset = AVURLAsset(url: url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw ReadError.unreadable(error.localizedDescription)
            }
            guard !tracks.isEmpty else { throw ReadError.noAudioTrack }

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw ReadError.unreadable(error.localizedDescription)
            }

            // The mix output does the format conversion itself — downmix,
            // resample and float conversion in one pass, in AVFoundation's C
            // code rather than ours.
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: tracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: AudioCapture.targetSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ReadError.unreadable("that audio format can't be decoded")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw ReadError.unreadable(reader.error?.localizedDescription ?? "decoder wouldn't start")
            }

            var samples: [Float] = []
            if let seconds = try? await asset.load(.duration), seconds.isNumeric {
                samples.reserveCapacity(Int(CMTimeGetSeconds(seconds) * AudioCapture.targetSampleRate))
            }

            while let buffer = output.copyNextSampleBuffer() {
                defer { CMSampleBufferInvalidate(buffer) }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                let count = bytes / MemoryLayout<Float>.size
                guard count > 0 else { continue }

                // Grow first, then copy into the tail — one pass over the
                // block buffer rather than an intermediate Data.
                let start = samples.count
                samples.append(contentsOf: repeatElement(0, count: count))
                let status = samples.withUnsafeMutableBufferPointer { pointer in
                    CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: bytes,
                        destination: pointer.baseAddress! + start
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    samples.removeLast(count)
                    throw ReadError.unreadable("decoder returned a bad buffer")
                }
            }

            if reader.status == .failed {
                throw ReadError.unreadable(reader.error?.localizedDescription ?? "decode failed")
            }
            guard !samples.isEmpty else { throw ReadError.empty }
            return samples
        }.value
    }
}
