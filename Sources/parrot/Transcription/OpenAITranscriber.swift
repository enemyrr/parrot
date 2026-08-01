import Foundation

/// Transcription via OpenAI's `/v1/audio/transcriptions`.
///
/// The opposite trade to Parakeet on every axis: a network round trip instead
/// of a fraction of a second on the Neural Engine, a per-minute cost instead of
/// a one-off download, and the audio leaving the machine. What it buys is the
/// two things the local decoder structurally cannot do — languages outside
/// Parakeet's 25, and *steering*: `keywords` and `languages` condition the
/// decode itself, where the wordlist can only patch the transcript afterwards.
///
/// A struct, not an actor: there is no model to load and no state to guard, so
/// concurrent calls are simply concurrent requests.
struct OpenAITranscriber: Transcriber {
    let modelID: String
    private let apiModel: String

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Deliberately not a setting. Cleanup has a tight, tunable timeout because
    /// it can fall back to the raw transcript; transcription has nothing to
    /// fall back to, so the only thing a short deadline buys is losing the
    /// dictation outright. Generous enough for a long hands-free recording on
    /// a bad connection, short enough not to hang forever.
    private static let timeout: Double = 60

    /// The endpoint caps uploads at 25 MB. At 16 kHz 16-bit mono that is a hair
    /// over 13 minutes, and refusing up front is a better answer than shipping
    /// the bytes to be rejected.
    static let maxSeconds = 13.0 * 60

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.apiModel = model.engineModelID ?? model.id
    }

    /// Nothing to load. The key is checked here anyway so a missing one shows
    /// up in the status bar at launch rather than swallowing the first
    /// dictation of the day.
    func warmUp() async throws {
        guard Keychain.apiKey(for: .openai) != nil else {
            throw TranscriberError.missingAPIKey(.openai)
        }
    }

    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> String {
        // Length before key on purpose. A missing key has already been reported
        // by `warmUp` — it is sitting in the status bar and the menu bar before
        // the hotkey is ever pressed — whereas the length ceiling can only be
        // discovered here, and it is the finding worth surfacing.
        let seconds = Double(audio.count) / AudioCapture.targetSampleRate
        guard seconds <= Self.maxSeconds else {
            throw TranscriberError.audioTooLong(seconds: seconds, limit: Self.maxSeconds)
        }
        guard let key = Keychain.apiKey(for: .openai) else {
            throw TranscriberError.missingAPIKey(.openai)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let boundary = "parrot-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body(audio: audio, context: context, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // A dictation tool that dies on a dropped connection is worse than
            // one that says so, and this is the message the pipeline logs.
            throw TranscriberError.badResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriberError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw TranscriberError.badResponse(Self.errorDetail(status: http.statusCode, data: data))
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Request body

    /// Not private so the tests can read it back: a multipart body that is
    /// subtly wrong fails as a 400 at dictation time, which is the worst
    /// possible place to discover a missing CRLF.
    func body(
        audio: [Float],
        context: TranscriptionContext,
        boundary: String
    ) -> Data {
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        field("model", apiModel)
        field("response_format", "json")

        // `keywords` is a hint list, not a substitution list — the model only
        // emits one if it hears it. That is exactly the half of the wordlist's
        // job the decoder can do and a find/replace pass can't.
        for keyword in Self.sanitize(context.vocabulary) {
            field("keywords[]", keyword)
        }
        // Plural, and mutually exclusive with the older singular `language`:
        // gpt-transcribe takes the whole set, so someone who dictates in two
        // languages isn't made to pick one.
        for code in Self.normalize(context.languages) {
            field("languages[]", code)
        }

        let wav = WAVWriter.data(
            samples: audio,
            sampleRate: Int(AudioCapture.targetSampleRate)
        )
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8
        ))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Keywords may not contain angle brackets or newlines. Dropping the
    /// offending characters beats dropping the term, and beats a 400 for a
    /// stray line break someone pasted into the Dictionary pane.
    private static func sanitize(_ terms: [String]) -> [String] {
        terms.compactMap { term in
            let cleaned = term
                .components(separatedBy: CharacterSet(charactersIn: "<>\r\n"))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private static func normalize(_ codes: [String]) -> [String] {
        codes.compactMap { code in
            let normalised = code.lowercased().trimmingCharacters(in: .whitespaces)
            return normalised.isEmpty ? nil : normalised
        }
    }

    private static func errorDetail(status: Int, data: Data) -> String {
        if let err = try? JSONDecoder().decode(APIError.self, from: data) {
            return "HTTP \(status): \(err.error.message)"
        }
        return "HTTP \(status)"
    }

    // MARK: - Wire types

    private struct Response: Decodable {
        let text: String
    }

    private struct APIError: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}
