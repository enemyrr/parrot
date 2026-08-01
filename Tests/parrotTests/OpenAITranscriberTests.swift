import XCTest

@testable import parrot

/// The request body is the whole of this transcriber. It is assembled by hand
/// rather than by a form encoder, and every mistake it can make — a missing
/// CRLF, a singular `language`, a keyword with a newline in it — surfaces as an
/// opaque 400 in the middle of someone's dictation.
final class OpenAITranscriberTests: XCTestCase {
    private let model = TranscriptionModel(
        id: "gpt-transcribe",
        displayName: "GPT Transcribe (OpenAI)",
        engine: .openai,
        engineModelID: "gpt-transcribe",
        sizeMB: 0,
        languages: ["multi"],
        recommended: false
    )

    private func body(_ context: TranscriptionContext, samples: [Float] = [0, 0.5, -0.5]) -> String {
        let data = OpenAITranscriber(model: model)
            .body(audio: samples, context: context, boundary: "B")
        // The audio is binary, so decode leniently — every assertion here is
        // about the text parts around it.
        return String(decoding: data, as: UTF8.self)
    }

    func testCarriesTheAPIModelNameNotTheRegistryID() {
        XCTAssertTrue(body(.empty).contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
    }

    func testSendsOneKeywordFieldPerVocabularyTerm() {
        let text = body(TranscriptionContext(vocabulary: ["Vercel", "Parakeet"], languages: []))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nVercel\r\n"))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nParakeet\r\n"))
    }

    /// gpt-transcribe takes `languages` plural and rejects the older singular
    /// field alongside it, so someone who dictates in two never has to pick one.
    func testSendsPluralLanguagesAndNeverTheSingularField() {
        let text = body(TranscriptionContext(vocabulary: [], languages: ["EN", " sv "]))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nen\r\n"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nsv\r\n"))
        XCTAssertFalse(text.contains("name=\"language\""))
    }

    /// Angle brackets and line breaks are rejected by the endpoint. A term
    /// someone pasted with a stray newline should lose the newline, not the
    /// term, and must never take the whole request down with it.
    func testStripsCharactersKeywordsMayNotContain() {
        let text = body(TranscriptionContext(vocabulary: ["a<b>c", "two\nlines", "  "], languages: []))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\na b c\r\n"))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\ntwo lines\r\n"))
        // The blank one is dropped rather than sent as an empty hint.
        XCTAssertEqual(text.components(separatedBy: "name=\"keywords[]\"").count - 1, 2)
    }

    func testOmitsHintFieldsEntirelyWhenThereAreNone() {
        let text = body(.empty)
        XCTAssertFalse(text.contains("keywords[]"))
        XCTAssertFalse(text.contains("languages[]"))
    }

    func testClosesTheMultipartBodyWithTheTerminatingBoundary() {
        let text = body(.empty)
        XCTAssertTrue(text.contains("filename=\"audio.wav\""))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }

    /// The endpoint caps uploads at 25 MB; refusing up front beats uploading
    /// ten minutes of audio to have it rejected.
    func testRejectsAudioLongerThanTheUploadLimit() async {
        let samples = [Float](
            repeating: 0,
            count: Int(AudioCapture.targetSampleRate * (OpenAITranscriber.maxSeconds + 1))
        )
        do {
            _ = try await OpenAITranscriber(model: model).transcribe(samples, context: .empty)
            XCTFail("expected the length guard to reject this")
        } catch TranscriberError.audioTooLong {
            // expected
        } catch TranscriberError.missingAPIKey {
            XCTFail("the length check must not depend on a key being present")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// The registry gained an entry that isn't a file on disk, and most of the
/// model layer is written around the assumption that a model is one.
final class RemoteModelTests: XCTestCase {
    private var remote: TranscriptionModel {
        ModelRegistry.find("gpt-transcribe")!
    }

    /// The daemon gates engine loading on `isDownloaded`. Answering false for a
    /// model with nothing to fetch would park it in the download branch forever.
    func testARemoteModelCountsAsDownloaded() {
        XCTAssertFalse(remote.isLocal)
        XCTAssertTrue(remote.isDownloaded)
    }

    func testMultiMeansSomethingDifferentPerEngine() {
        XCTAssertEqual(remote.languageSummary, "100+ languages")
        XCTAssertEqual(ModelRegistry.find("parakeet-v3")?.languageSummary, "25 languages")
        XCTAssertEqual(ModelRegistry.find("parakeet-v2")?.languageSummary, "en")
    }

    /// Local stays the default: the cloud model is slower and costs money, so
    /// nobody should land on it without choosing it.
    func testTheRecommendedModelIsLocal() {
        XCTAssertEqual(ModelRegistry.recommended()?.isLocal, true)
    }
}

final class WAVWriterTests: XCTestCase {
    /// 44-byte canonical header, then two bytes per sample.
    func testWritesACanonicalHeaderAndOneInt16PerSample() {
        let data = WAVWriter.data(samples: [0, 1, -1], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))

        // Full scale in both directions, clamped rather than wrapped — a
        // wrapped +1.0 would come back as the loudest possible *negative*
        // sample and sound like a click.
        let samples = data[44...].withUnsafeBytes { raw in
            (0..<3).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        XCTAssertEqual(samples, [0, 32767, -32767])
    }
}
