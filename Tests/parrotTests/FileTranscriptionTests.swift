import XCTest

@testable import parrot

/// The file path shares an engine with dictation and nothing else: no cursor,
/// no shortcuts, no cap on how long the recording is. These pin the three
/// places that difference is load-bearing — decoding an arbitrary container,
/// cutting a transcript small enough to clean, and what ends up in history.
final class FileTranscriptionTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-file-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - Decoding

    /// A tone written by parrot's own WAV writer, read back through the asset
    /// reader. Round-tripping the two says the decoder agrees with the format
    /// the rest of the app produces.
    func testDecodesAWAVBackToTheSampleRateTheEnginesTake() async throws {
        let seconds = 1.5
        let count = Int(AudioCapture.targetSampleRate * seconds)
        let tone = (0..<count).map { index in
            sin(2 * Float.pi * 440 * Float(index) / Float(AudioCapture.targetSampleRate)) * 0.5
        }
        let url = scratch.appendingPathComponent("tone.wav")
        try WAVWriter.write(samples: tone, sampleRate: Int(AudioCapture.targetSampleRate), to: url.path)

        let decoded = try await AudioFileReader.samples(at: url)

        // Codecs pad and trim at the edges; within a few milliseconds is the
        // right tolerance for "this is the same recording".
        XCTAssertEqual(Double(decoded.count), Double(count), accuracy: AudioCapture.targetSampleRate * 0.05)
        XCTAssertEqual(computeRMS(decoded), computeRMS(tone), accuracy: 0.05)
    }

    func testDurationReadsTheRecordingsLength() async throws {
        let count = Int(AudioCapture.targetSampleRate * 2)
        let url = scratch.appendingPathComponent("two-seconds.wav")
        try WAVWriter.write(
            samples: [Float](repeating: 0.1, count: count),
            sampleRate: Int(AudioCapture.targetSampleRate),
            to: url.path
        )

        let seconds = await AudioFileReader.duration(of: url)
        XCTAssertEqual(try XCTUnwrap(seconds), 2.0, accuracy: 0.1)
    }

    func testRefusesAFileThatIsNotThere() async {
        let url = scratch.appendingPathComponent("nothing.wav")
        do {
            _ = try await AudioFileReader.samples(at: url)
            XCTFail("expected a read error")
        } catch let error as AudioFileReader.ReadError {
            guard case .missingFile = error else {
                return XCTFail("expected missingFile, got \(error)")
            }
        } catch {
            XCTFail("expected a ReadError, got \(error)")
        }
    }

    func testWAVIsHandedToTheStreamingPathAndTextIsNot() throws {
        let audio = scratch.appendingPathComponent("tone.wav")
        try WAVWriter.write(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, to: audio.path)
        let text = scratch.appendingPathComponent("notes.txt")
        try "not audio".write(to: text, atomically: true, encoding: .utf8)

        XCTAssertTrue(AudioFileReader.isPlainAudioFile(audio))
        XCTAssertFalse(AudioFileReader.isPlainAudioFile(text))
    }

    // MARK: - Chunking

    func testShortTranscriptIsOneChunk() {
        let chunks = TranscriptChunker.chunks(of: "One sentence. And a second.")
        XCTAssertEqual(chunks, ["One sentence. And a second."])
    }

    func testEmptyTranscriptProducesNoChunks() {
        XCTAssertTrue(TranscriptChunker.chunks(of: "   \n ").isEmpty)
    }

    func testSplitsOnSentenceEndingsRatherThanMidSentence() {
        let sentence = "This is a sentence with exactly ten words in it. "
        let transcript = String(repeating: sentence, count: 40)  // 400 words

        let chunks = TranscriptChunker.chunks(of: transcript, maxWords: 100)

        XCTAssertEqual(chunks.count, 4)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasSuffix("."), "chunk ended mid-sentence: …\(chunk.suffix(30))")
            XCTAssertLessThanOrEqual(chunk.split(whereSeparator: \.isWhitespace).count, 100)
        }
    }

    /// Raw ASR output of a monologue can run for thousands of words without a
    /// full stop. Sentence boundaries alone would hand the model the lot.
    func testARunawaySentenceIsSplitOnWords() {
        let transcript = (1...250).map { "word\($0)" }.joined(separator: " ")

        let chunks = TranscriptChunker.chunks(of: transcript, maxWords: 100)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map { $0.split(whereSeparator: \.isWhitespace).count }, [100, 100, 50])
    }

    func testChunkingKeepsEveryWordInOrder() {
        let transcript = (1...500).map { "word\($0)." }.joined(separator: " ")

        let rejoined = TranscriptChunker.chunks(of: transcript, maxWords: 60)
            .joined(separator: " ")

        XCTAssertEqual(
            rejoined.split(whereSeparator: \.isWhitespace),
            transcript.split(whereSeparator: \.isWhitespace)
        )
    }

    // MARK: - The pipeline

    func testAppliesTheWordlistAndStoresTheRunAsAFile() async throws {
        let history = scratch.appendingPathComponent("history.jsonl")
        let store = TranscriptStore(settings: .default, url: history)
        var wordlist = WordlistSettings.default
        wordlist.replacements = [Replacement(from: "parrot", to: "Parrot")]

        let outcome = try await pipeline(
            saying: "hello from parrot",
            wordlist: Wordlist(settings: wordlist),
            store: store
        ).run(url: try toneFile())

        XCTAssertEqual(outcome.text, "hello from Parrot")
        XCTAssertEqual(outcome.raw, "hello from parrot")
        XCTAssertFalse(outcome.cleaned)

        let stored = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(stored.text, "hello from Parrot")
        XCTAssertEqual(stored.mode, .file)
        // A file was never held down, and calling it hands-free would put a
        // padlock next to it in the history list.
        XCTAssertFalse(stored.latched)
    }

    func testSilenceIsReportedRatherThanStoredAsAnEmptyTranscript() async throws {
        let history = scratch.appendingPathComponent("history.jsonl")
        let store = TranscriptStore(settings: .default, url: history)

        do {
            _ = try await pipeline(saying: "", store: store).run(url: try toneFile())
            XCTFail("expected silence to throw")
        } catch let error as FileTranscription.FileError {
            guard case .silence = error else { return XCTFail("expected silence, got \(error)") }
        }

        XCTAssertTrue(store.recent(1).isEmpty)
    }

    /// The API model's own ceiling, restated. "recording is 4200s" describes a
    /// recording nobody made, and doesn't say what to do instead.
    func testTheCloudLengthCapIsRestatedAsSomethingToDoAboutIt() async throws {
        let failing = StubTranscriber(
            text: "",
            error: TranscriberError.audioTooLong(seconds: 4200, limit: 780)
        )

        do {
            _ = try await pipeline(transcriber: failing).run(url: try toneFile())
            XCTFail("expected the length cap to throw")
        } catch let error as FileTranscription.FileError {
            guard case .tooLongForModel = error else {
                return XCTFail("expected tooLongForModel, got \(error)")
            }
            XCTAssertTrue(error.description.contains("70:00"))
            XCTAssertTrue(error.description.contains("local model"))
        }
    }

    // MARK: - Helpers

    private func toneFile() throws -> URL {
        let url = scratch.appendingPathComponent("tone-\(UUID().uuidString).wav")
        try WAVWriter.write(
            samples: [Float](repeating: 0.1, count: 16_000),
            sampleRate: 16_000,
            to: url.path
        )
        return url
    }

    private func pipeline(
        saying text: String = "hello",
        transcriber: Transcriber? = nil,
        wordlist: Wordlist = Wordlist(settings: .default),
        store: TranscriptStore? = nil
    ) -> FileTranscription {
        FileTranscription(
            transcriber: transcriber ?? StubTranscriber(text: text),
            wordlist: wordlist,
            cleaner: nil,
            cleanup: .default,
            store: store,
            languages: [],
            transcription: .empty,
            modelID: "stub"
        )
    }
}

/// Stands in for an engine. The file path's own logic is everything around the
/// transcription, so the transcription itself is the part worth faking.
private struct StubTranscriber: Transcriber {
    let modelID = "stub"
    let text: String
    var error: Error?

    init(text: String, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> String {
        if let error { throw error }
        return text
    }
}
