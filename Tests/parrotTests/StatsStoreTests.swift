import XCTest

@testable import parrot

/// One folded row per day per model, atomically rewritten on each dictation.
/// The invariants that matter: folding never loses a counter, and the history
/// backfill can't run twice — it would double every total.
final class StatsStoreTests: XCTestCase {
    private var url: URL!
    private var historyURL: URL!

    /// Fixed so day keys don't drift with the machine's clock settings.
    private let zone = TimeZone(identifier: "UTC")!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-stats-\(id).jsonl")
        historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-stats-history-\(id).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: historyURL)
        super.tearDown()
    }

    private func store(enabled: Bool = true) -> StatsStore {
        var settings = StatsSettings.default
        settings.enabled = enabled
        return StatsStore(settings: settings, url: url, historyURL: historyURL, timeZone: zone)
    }

    /// 2023-11-14T22:13:20Z, plus whole days.
    private func date(dayOffset: Int = 0, secondsOffset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(dayOffset) * 86400 + secondsOffset)
    }

    private func lineCount() -> Int {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return data.split(separator: 0x0A).count
    }

    // MARK: - record / fold

    func testRecordAccumulatesWithinADay() {
        let s = store()
        s.record(text: "one two three", spokenSeconds: 3, processSeconds: 0.5,
                 latched: false, model: "parakeet-v3", at: date())
        s.record(text: "four five", spokenSeconds: 2, processSeconds: 0.7,
                 latched: true, model: "parakeet-v3", at: date(secondsOffset: 60))

        let days = s.days()
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].sessions, 2)
        XCTAssertEqual(days[0].words, 5)
        XCTAssertEqual(days[0].spokenSeconds, 5)
        XCTAssertEqual(days[0].latched, 1)
        XCTAssertEqual(days[0].processSamples, 2)
    }

    func testRecordSplitsByDayAndModel() {
        let s = store()
        s.record(text: "a b", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "parakeet-v3", at: date())
        s.record(text: "c", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "whisper", at: date())
        s.record(text: "d", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "parakeet-v3", at: date(dayOffset: 1))

        XCTAssertEqual(s.days().count, 3)
        XCTAssertEqual(Set(s.days().map(\.day)).count, 2)
    }

    func testEmptyTextIsNotRecorded() {
        let s = store()
        s.record(text: "   ", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "m", at: date())
        XCTAssertTrue(s.days().isEmpty)
    }

    func testRecordIsDisabledWhenStatsAreOff() {
        let s = store(enabled: false)
        s.record(text: "hello there", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "m", at: date())
        XCTAssertTrue(s.days().isEmpty)
    }

    func testCorruptLineIsSkippedWithoutLosingTheRest() {
        let s = store()
        s.record(text: "one two", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "m", at: date())
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data("{not json\n".utf8))
        try! handle.close()

        XCTAssertEqual(s.days().first?.words, 2)
    }

    func testRecordKeepsOneLinePerDayAndModel() {
        let s = store()
        for i in 0..<10 {
            s.record(text: "one two", spokenSeconds: 1, processSeconds: 0.5,
                     latched: false, model: "m", at: date(secondsOffset: Double(i)))
        }
        XCTAssertEqual(lineCount(), 1)
        XCTAssertEqual(s.days().first?.words, 20)
        XCTAssertEqual(s.days().first?.sessions, 10)
    }

    // MARK: - backfill

    private func writeHistory(_ entries: [TranscriptEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var out = Data()
        for entry in entries {
            out.append(try! encoder.encode(entry))
            out.append(0x0A)
        }
        try! out.write(to: historyURL)
    }

    private func historyEntry(_ text: String, at when: Date, model: String = "parakeet-v3")
        -> TranscriptEntry
    {
        TranscriptEntry(at: when, raw: text, text: text, model: model,
                        seconds: 2, latched: false, cleaned: false)
    }

    func testBackfillImportsHistory() {
        writeHistory([
            historyEntry("one two three", at: date()),
            historyEntry("four five", at: date(dayOffset: 1)),
        ])
        let s = store()
        s.backfillFromHistoryIfNeeded()

        let summary = StatsSummary(days: s.days(), typingWpm: 40)
        XCTAssertEqual(summary.words, 5)
        XCTAssertEqual(summary.daysUsed, 2)
    }

    /// The one that would silently double every number the user sees.
    func testBackfillRunsOnlyOnce() {
        writeHistory([historyEntry("one two three", at: date())])
        let s = store()
        s.backfillFromHistoryIfNeeded()
        s.backfillFromHistoryIfNeeded()
        XCTAssertEqual(s.days().reduce(0) { $0 + $1.words }, 3)
    }

    /// Backfill must create the file even with nothing to import, or history
    /// written later would be imported on top of stats already counted live.
    func testBackfillWithNoHistoryStillMarksItselfDone() {
        let s = store()
        s.backfillFromHistoryIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        writeHistory([historyEntry("one two three", at: date())])
        s.backfillFromHistoryIfNeeded()
        XCTAssertTrue(s.days().isEmpty)
    }

    func testBackfillLeavesNoLatencySamples() {
        writeHistory([historyEntry("one two three", at: date())])
        let s = store()
        s.backfillFromHistoryIfNeeded()

        let summary = StatsSummary(days: s.days(), typingWpm: 40)
        XCTAssertNil(summary.models.first?.averageProcessSeconds,
                     "history never recorded latency, so there is no mean to report")
    }

    func testResetKeepsBackfillFromReimportingHistory() {
        writeHistory([historyEntry("one two three", at: date())])
        let s = store()
        s.backfillFromHistoryIfNeeded()
        try! s.reset()
        s.backfillFromHistoryIfNeeded()
        XCTAssertTrue(s.days().isEmpty, "cleared stats must stay cleared")
    }

    // MARK: - daily / summary

    func testDailyIncludesGapsAndEndsToday() {
        let s = store()
        s.record(text: "one two", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "m", at: date(dayOffset: -2))
        let points = s.daily(lastDays: 3, from: date())
        XCTAssertEqual(points.map(\.words), [2, 0, 0])
    }

    func testSummaryDerivesSpeedAndTimeSaved() {
        let s = store()
        // 100 words in 60s of speech: 100 wpm spoken, 150s to type at 40 wpm.
        s.record(text: Array(repeating: "word", count: 100).joined(separator: " "),
                 spokenSeconds: 60, processSeconds: 1, latched: true, model: "m", at: date())

        let summary = s.summary(typingWpm: 40)
        XCTAssertEqual(summary.averageWpm, 100, accuracy: 0.001)
        XCTAssertEqual(summary.secondsSaved, 90, accuracy: 0.001)
        XCTAssertEqual(summary.latchedShare, 1)
    }

    func testTimeSavedNeverGoesNegative() {
        let s = store()
        // Ten words spread over five minutes is slower than anyone types.
        s.record(text: Array(repeating: "word", count: 10).joined(separator: " "),
                 spokenSeconds: 300, processSeconds: 1, latched: false, model: "m", at: date())
        XCTAssertEqual(s.summary(typingWpm: 40).secondsSaved, 0)
    }

    func testSummaryOfNothingIsAllZero() {
        let summary = StatsSummary(days: [], typingWpm: 40)
        XCTAssertEqual(summary.words, 0)
        XCTAssertEqual(summary.averageWpm, 0)
        XCTAssertEqual(summary.secondsSaved, 0)
        XCTAssertEqual(summary.latchedShare, 0)
        XCTAssertTrue(summary.models.isEmpty)
    }

    func testPerModelLatencyAveragesOverSamplesOnly() {
        let s = store()
        s.record(text: "one two", spokenSeconds: 1, processSeconds: 1.0,
                 latched: false, model: "m", at: date())
        s.record(text: "three four", spokenSeconds: 1, processSeconds: 2.0,
                 latched: false, model: "m", at: date())
        XCTAssertEqual(s.summary(typingWpm: 40).models.first?.averageProcessSeconds ?? 0,
                       1.5, accuracy: 0.001)
    }

    func testStatsFileIsNotWorldReadable() {
        let s = store()
        s.record(text: "one two", spokenSeconds: 1, processSeconds: 0.1,
                 latched: false, model: "m", at: date())
        let perms = try! FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.intValue & 0o077, 0)
    }

    // MARK: - sparkline

    func testSparklineMarksEmptyDaysAndScalesToPeak() {
        XCTAssertEqual(Stats.sparkline([0, 0]), "")
        XCTAssertEqual(Stats.sparkline([0, 10]), "·█")
        // A one-word day must not render as an empty day.
        XCTAssertEqual(Stats.sparkline([1, 100]).first, "▁")
    }

    func testDurationPicksAReadableUnit() {
        XCTAssertEqual(Stats.duration(45), "45s")
        XCTAssertEqual(Stats.duration(420), "7 min")
        XCTAssertEqual(Stats.duration(3600), "1 h")
        XCTAssertEqual(Stats.duration(4320), "1 h 12 min")
    }
}
