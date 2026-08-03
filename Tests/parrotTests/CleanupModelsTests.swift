import XCTest

@testable import parrot

/// The list endpoints hand back everything the account can reach, most of which
/// the cleanup call would reject. What survives the filter is what someone is
/// offered in a menu, so a mistake here reads as "that model doesn't exist".
final class CleanupModelsTests: XCTestCase {
    // MARK: - OpenAI filtering

    func testKeepsChatModels() {
        // The cleanup defaults are in here on purpose: a default the filter
        // hides is a default the picker can never show as selected.
        for id in [
            OpenAICleaner.defaultModel, "gpt-5-mini", "gpt-4.1",
            "chatgpt-4o-latest", "o3", "o4-mini",
        ] {
            XCTAssertTrue(CleanupModels.isChatModel(id), id)
        }
    }

    func testDropsModelsThatArentForText() {
        for id in [
            "whisper-1", "tts-1", "dall-e-3", "text-embedding-3-small",
            "omni-moderation-latest", "gpt-image-1", "gpt-4o-mini-tts",
            "gpt-4o-realtime-preview", "gpt-4o-transcribe", "gpt-4o-search-preview",
            "gpt-3.5-turbo-instruct", "gpt-5-codex",
        ] {
            XCTAssertFalse(CleanupModels.isChatModel(id), id)
        }
    }

    // MARK: - Decoding

    func testSortsOpenAIModelsNewestFirst() throws {
        let json = """
        {"object": "list", "data": [
            {"id": "gpt-4.1", "created": 100},
            {"id": "whisper-1", "created": 300},
            {"id": "gpt-5-mini", "created": 200}
        ]}
        """
        let models = try CleanupModels.openAIModels(from: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-5-mini", "gpt-4.1"])
        // OpenAI has no names for its models, so the id has to do both jobs.
        XCTAssertEqual(models.first?.displayName, "gpt-5-mini")
    }

    func testKeepsAnthropicOrderAndDisplayNames() throws {
        let json = """
        {"data": [
            {"type": "model", "id": "claude-opus-4-5", "display_name": "Claude Opus 4.5"},
            {"type": "model", "id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5"}
        ], "has_more": false}
        """
        let models = try CleanupModels.anthropicModels(from: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["claude-opus-4-5", "claude-haiku-4-5"])
        XCTAssertEqual(models.map(\.displayName), ["Claude Opus 4.5", "Claude Haiku 4.5"])
    }

    /// A model without a name still has to be pickable.
    func testFallsBackToTheIDWhenThereIsNoDisplayName() throws {
        let json = #"{"data": [{"id": "claude-future-1"}]}"#
        let models = try CleanupModels.anthropicModels(from: Data(json.utf8))
        XCTAssertEqual(models.first?.displayName, "claude-future-1")
    }

    func testSurfacesAReadableErrorForAnUnreadableList() {
        XCTAssertThrowsError(try CleanupModels.openAIModels(from: Data("not json".utf8))) { error in
            XCTAssertEqual("\(error)", "couldn't read the model list")
        }
    }

    // MARK: - Cache

    /// A scratch suite, so a test run can't drop the list the app is using.
    private static let suite = "com.enemyrr.parrot.tests.modelcache"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suite)
        CleanupModels.Cache.defaults = UserDefaults(suiteName: Self.suite)!
    }

    private let models = [CleanupModels.Model(id: "gpt-5", displayName: "gpt-5")]

    func testServesASavedListBack() {
        CleanupModels.Cache.save(models, for: .openai, key: "sk-one")
        XCTAssertEqual(CleanupModels.Cache.load(.openai, key: "sk-one"), models)
    }

    /// Each provider's list is its own; one saving must not answer for another.
    func testKeepsProvidersApart() {
        CleanupModels.Cache.save(models, for: .openai, key: "sk-one")
        XCTAssertNil(CleanupModels.Cache.load(.anthropic, key: "sk-one"))
    }

    /// A new key is a different account, which can reach a different set of
    /// models — serving the old list would show models it can't call.
    func testMissesWhenTheKeyChanged() {
        CleanupModels.Cache.save(models, for: .openai, key: "sk-one")
        XCTAssertNil(CleanupModels.Cache.load(.openai, key: "sk-two"))
    }

    func testExpiresAfterADay() {
        CleanupModels.Cache.save(models, for: .openai, key: "sk-one")
        let lifetime = CleanupModels.Cache.lifetime
        XCTAssertNotNil(
            CleanupModels.Cache.load(.openai, key: "sk-one", now: Date().addingTimeInterval(lifetime - 60))
        )
        XCTAssertNil(
            CleanupModels.Cache.load(.openai, key: "sk-one", now: Date().addingTimeInterval(lifetime + 60))
        )
    }

    /// An empty list is a picker with nothing in it; caching that for a day
    /// would strand someone whose key was briefly rejected.
    func testDoesNotServeAnEmptyList() {
        CleanupModels.Cache.save([], for: .openai, key: "sk-one")
        XCTAssertNil(CleanupModels.Cache.load(.openai, key: "sk-one"))
    }
}
