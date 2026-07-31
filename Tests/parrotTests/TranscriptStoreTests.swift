import XCTest

@testable import parrot

/// `recent()` backs the menu bar's Recent submenu, so it runs on every menu
/// open. It decodes only the tail of the file rather than the whole history;
/// these tests pin the behaviour that shortcut has to preserve.
final class TranscriptStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-test-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func store(maxEntries: Int = 5000) -> TranscriptStore {
        var settings = HistorySettings.default
        settings.maxEntries = maxEntries
        return TranscriptStore(settings: settings, url: url)
    }

    private func entry(_ text: String, at offset: TimeInterval = 0) -> TranscriptEntry {
        TranscriptEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            raw: text,
            text: text,
            model: "parakeet-v3",
            seconds: 1.0,
            latched: false,
            cleaned: false
        )
    }

    private func fill(_ s: TranscriptStore, count: Int) {
        for i in 0..<count {
            s.append(entry("entry \(i)", at: TimeInterval(i)))
        }
    }

    // MARK: - recent()

    func testRecentIsEmptyWhenNoFileExists() {
        XCTAssertTrue(store().recent(10).isEmpty)
    }

    func testRecentReturnsNewestFirst() {
        let s = store()
        fill(s, count: 5)
        XCTAssertEqual(s.recent(3).map(\.text), ["entry 4", "entry 3", "entry 2"])
    }

    func testRecentReturnsEverythingWhenFileIsShorterThanRequested() {
        let s = store()
        fill(s, count: 3)
        XCTAssertEqual(s.recent(10).map(\.text), ["entry 2", "entry 1", "entry 0"])
    }

    func testRecentZeroReturnsNothing() {
        let s = store()
        fill(s, count: 3)
        XCTAssertTrue(s.recent(0).isEmpty)
    }

    func testRecentMatchesAllPrefixForWholeFile() {
        let s = store()
        fill(s, count: 40)
        // The fast path and the read-everything path must not disagree.
        XCTAssertEqual(s.recent(10).map(\.text), Array(s.all().prefix(10)).map(\.text))
    }

    func testRecentSkipsCorruptTrailingLine() {
        let s = store()
        fill(s, count: 3)
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data("{not json\n".utf8))
        try! handle.close()

        // The bad line consumes a slot but must not take the file down with it.
        XCTAssertEqual(s.recent(4).map(\.text), ["entry 2", "entry 1", "entry 0"])
    }

    func testRecentHandlesFileWithoutTrailingNewline() {
        try! Data(#"{"at":"2023-11-14T22:13:20Z","raw":"a","text":"a","model":"m","seconds":1,"latched":false,"cleaned":false}"#.utf8)
            .write(to: url)
        XCTAssertEqual(store().recent(5).map(\.text), ["a"])
    }

    // MARK: - append / search / prune

    func testAppendIsDisabledWhenHistoryIsOff() {
        var settings = HistorySettings.default
        settings.enabled = false
        let s = TranscriptStore(settings: settings, url: url)
        s.append(entry("nope"))
        XCTAssertTrue(s.recent(10).isEmpty)
    }

    func testSearchIsCaseInsensitive() {
        let s = store()
        s.append(entry("Hello World"))
        s.append(entry("goodbye"))
        XCTAssertEqual(s.search("hello", limit: 10).map(\.text), ["Hello World"])
    }

    func testPruneTrimsOldestFirst() {
        let s = store(maxEntries: 5)
        fill(s, count: 12)
        s.prune()
        let all = s.all()
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map(\.text), ["entry 11", "entry 10", "entry 9", "entry 8", "entry 7"])
        XCTAssertEqual(s.recent(2).map(\.text), ["entry 11", "entry 10"])
    }

    func testClearEmptiesTheFile() {
        let s = store()
        fill(s, count: 3)
        try! s.clear()
        XCTAssertTrue(s.recent(10).isEmpty)
    }

    func testHistoryFileIsNotWorldReadable() {
        let s = store()
        fill(s, count: 1)
        let perms = try! FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.intValue & 0o077, 0, "history holds everything ever dictated")
    }
}
