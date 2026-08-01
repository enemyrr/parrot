import AVFoundation
import XCTest

@testable import parrot

/// A real round trip against `api.openai.com`, skipped unless asked for:
///
///     PARROT_LIVE_API=1 swift test --filter OpenAITranscriberLive
///
/// Opt-in because it costs money, needs a key and a connection, and is the only
/// test here that can fail for reasons that have nothing to do with the code.
/// It exists because everything else about this transcriber is verified against
/// a *documented* schema — this is the only thing that verifies the schema was
/// documented the way we read it.
final class OpenAITranscriberLiveTests: XCTestCase {
    private var model: TranscriptionModel {
        ModelRegistry.find("gpt-transcribe")!
    }

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARROT_LIVE_API"] == "1",
            "set PARROT_LIVE_API=1 to run live API tests"
        )
        try XCTSkipIf(Keychain.apiKey(for: .openai) == nil, "no OpenAI key available")
    }

    /// Synthesised rather than recorded so the test carries no audio fixture and
    /// the expected words are known exactly.
    private func speech(_ text: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
        let aiff = directory.appendingPathComponent("parrot-live-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }

        try run("/usr/bin/say", ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", [
            "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path,
        ])

        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw XCTSkip("couldn't allocate a read buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("no float channel in the decoded file")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "\(path) failed")
    }

    func testTranscribesRealSpeech() async throws {
        try skipUnlessEnabled()
        let samples = try speech("The quick brown fox jumps over the lazy dog.")

        let started = Date()
        let text = try await OpenAITranscriber(model: model)
            .transcribe(samples, context: .empty)
        let elapsed = Date().timeIntervalSince(started)

        print("live transcript (\(String(format: "%.2f", elapsed))s): \(text)")
        XCTAssertTrue(text.lowercased().contains("quick brown fox"), "got: \(text)")
    }

    /// The reason the cloud model exists. The wordlist can only rewrite the
    /// transcript afterwards; `keywords` reaches the decoder, so an unusual
    /// term should survive without any find/replace rule behind it.
    func testKeywordsReachTheDecoder() async throws {
        try skipUnlessEnabled()
        let samples = try speech("We should ship the Vercel integration and the Parakeet TDT model.")

        let context = TranscriptionContext(
            vocabulary: ["Vercel", "Parakeet TDT"],
            languages: ["en"]
        )
        let text = try await OpenAITranscriber(model: model)
            .transcribe(samples, context: context)

        print("live transcript with keywords: \(text)")
        XCTAssertTrue(text.contains("Vercel"), "got: \(text)")
        XCTAssertTrue(text.contains("Parakeet"), "got: \(text)")
    }

    /// A wrong key has to arrive as a legible message, not a decode failure —
    /// this is the error someone actually hits, on their first attempt.
    func testAnInvalidKeyReportsWhatTheAPISaid() async throws {
        try skipUnlessEnabled()
        let saved = Keychain.read(.openai)
        try Keychain.write("sk-not-a-real-key", for: .openai)
        defer {
            if let saved { try? Keychain.write(saved, for: .openai) }
        }

        do {
            _ = try await OpenAITranscriber(model: model).transcribe([0, 0, 0], context: .empty)
            XCTFail("expected a rejection")
        } catch let error as TranscriberError {
            print("live auth failure: \(error.description)")
            XCTAssertTrue(error.description.contains("401"), "got: \(error.description)")
        }
    }
}
