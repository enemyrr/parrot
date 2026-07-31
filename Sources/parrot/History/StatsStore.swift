import Foundation

/// One local-calendar day's totals for one model.
///
/// Counters only — no dictated text ever lands here, which is why stats can
/// stay on for someone who has turned history off.
struct StatsDay: Codable, Equatable {
    let day: String
    let model: String
    var sessions: Int
    var words: Int
    var chars: Int
    var spokenSeconds: Double
    /// Transcribe + cleanup wall time. Rows backfilled from history carry no
    /// samples, so the mean is taken over `processSamples` rather than
    /// `sessions` — otherwise imported days would drag every model's latency
    /// toward zero.
    var processSeconds: Double
    var processSamples: Int
    var latched: Int

    fileprivate var key: String { "\(day)\u{1F}\(model)" }

    fileprivate mutating func merge(_ other: StatsDay) {
        sessions += other.sessions
        words += other.words
        chars += other.chars
        spokenSeconds += other.spokenSeconds
        processSeconds += other.processSeconds
        processSamples += other.processSamples
        latched += other.latched
    }
}

/// JSONL of per-day usage counters, one line per day per model.
///
/// Deliberately separate from `TranscriptStore`: history is pruned to
/// `max_entries` and can be cleared outright, so lifetime totals derived from
/// it would silently shrink. This file is never trimmed.
///
/// The daemon is the only writer (the CLI only reads), so each dictation
/// atomically rewrites the whole file with its day's row updated — it's
/// roughly 150 bytes per day of use, and the atomic write means a crash can't
/// tear it.
final class StatsStore {
    private let url: URL
    private let historyURL: URL
    private let enabled: Bool
    private let timeZone: TimeZone
    /// Shared across instances, not per-instance. `record` is a read-fold-
    /// rewrite of the whole file, and the settings window — which lives in the
    /// daemon's own process — builds its own `StatsStore` to reset from. Two
    /// locks would serialize nothing: a reset landing mid-record would be
    /// undone by the rewrite that follows it.
    private static let lock = NSLock()
    private var lock: NSLock { Self.lock }

    private static let encoder = JSONEncoder()

    private static let decoder = JSONDecoder()

    private static let historyDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        settings: StatsSettings,
        url: URL = ParrotPaths.statsFile,
        historyURL: URL = ParrotPaths.historyFile,
        timeZone: TimeZone = .current
    ) {
        self.url = url
        self.historyURL = historyURL
        self.enabled = settings.enabled
        self.timeZone = timeZone
    }

    var path: String { url.path }

    // MARK: - Writing

    func record(
        text: String,
        spokenSeconds: Double,
        processSeconds: Double,
        latched: Bool,
        model: String,
        at date: Date = Date()
    ) {
        guard enabled else { return }
        let words = Self.wordCount(text)
        guard words > 0 else { return }
        let row = StatsDay(
            day: dayKey(date),
            model: model,
            sessions: 1,
            words: words,
            chars: text.count,
            spokenSeconds: spokenSeconds,
            processSeconds: processSeconds,
            processSamples: 1,
            latched: latched ? 1 : 0
        )
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(Self.fold(loadUnlocked() + [row]))
    }

    /// Whitespace-split, matching the count `DictationPipeline` uses to decide
    /// whether cleanup is worth running. Undercounts CJK, which is fine for a
    /// usage total and not worth a tokenizer.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Reading

    /// One row per day per model, oldest first. Folded on read too, so a
    /// stats file written by the old delta-append format still sums correctly.
    func days() -> [StatsDay] {
        lock.lock()
        defer { lock.unlock() }
        return Self.fold(loadUnlocked())
    }

    func summary(typingWpm: Double) -> StatsSummary {
        StatsSummary(days: days(), typingWpm: typingWpm)
    }

    /// Words per day for the last `count` days, oldest first, including days
    /// with no dictation — a sparkline needs the gaps to be visible.
    func daily(lastDays count: Int, from now: Date = Date()) -> [(day: String, words: Int)] {
        guard count > 0 else { return [] }
        var totals: [String: Int] = [:]
        for row in days() {
            totals[row.day, default: 0] += row.words
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return (0..<count).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = dayKey(date)
            return (day: key, words: totals[key] ?? 0)
        }
    }

    // MARK: - Maintenance

    /// Import history into stats the first time stats runs, so an existing
    /// user's totals don't start at zero.
    ///
    /// Keyed on the stats file not existing, and the file is created either
    /// way — if this were allowed to run twice it would double-count every
    /// entry history still holds.
    func backfillFromHistoryIfNeeded() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        defer { try? ensureFileUnlocked() }
        guard let data = try? Data(contentsOf: historyURL) else { return }

        let rows = data.split(separator: 0x0A).compactMap { line -> StatsDay? in
            guard let entry = try? Self.historyDecoder.decode(
                TranscriptEntry.self, from: Data(line)
            ) else { return nil }
            let words = Self.wordCount(entry.text)
            guard words > 0 else { return nil }
            return StatsDay(
                day: dayKey(entry.at),
                model: entry.model,
                sessions: 1,
                words: words,
                chars: entry.text.count,
                spokenSeconds: entry.seconds,
                // History never recorded latency, so these rows contribute
                // nothing to the per-model averages.
                processSeconds: 0,
                processSamples: 0,
                latched: entry.latched ? 1 : 0
            )
        }
        guard !rows.isEmpty else { return }
        writeUnlocked(Self.fold(rows))
    }

    /// Truncate rather than delete, so the file still exists and backfill
    /// doesn't re-import history the user just asked to forget.
    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureFileUnlocked()
        try Data().write(to: url, options: .atomic)
    }

    // MARK: - Private

    private func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// In file order, skipping any line that fails to decode — a truncated
    /// write shouldn't cost the user their totals.
    private func loadUnlocked() -> [StatsDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? Self.decoder.decode(StatsDay.self, from: Data($0))
        }
    }

    private static func fold(_ rows: [StatsDay]) -> [StatsDay] {
        var merged: [String: StatsDay] = [:]
        for row in rows {
            if var existing = merged[row.key] {
                existing.merge(row)
                merged[row.key] = existing
            } else {
                merged[row.key] = row
            }
        }
        return merged.values.sorted {
            $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day
        }
    }

    private func writeUnlocked(_ rows: [StatsDay]) {
        var out = Data()
        for row in rows {
            guard var line = try? Self.encoder.encode(row) else { continue }
            line.append(0x0A)
            out.append(line)
        }
        do {
            try ensureFileUnlocked()
            try out.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            FileHandle.standardError.write(Data("  stats rewrite failed: \(error)\n".utf8))
        }
    }

    private func ensureFileUnlocked() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fm.fileExists(atPath: url.path) {
            // No transcript text in here, but it still describes when the
            // user is at their machine and for how long.
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }
}

// MARK: - Summary

/// The display numbers, derived rather than stored — `typing_wpm` is an
/// assumption the user can change, and baking it into the file would freeze
/// today's guess into every past day.
struct StatsSummary {
    struct Model {
        let model: String
        let words: Int
        let sessions: Int
        /// Nil when every row for this model came from the history backfill.
        let averageProcessSeconds: Double?
    }

    let words: Int
    let chars: Int
    let sessions: Int
    let spokenSeconds: Double
    let daysUsed: Int
    let averageWpm: Double
    let secondsSaved: Double
    let latchedShare: Double
    let models: [Model]

    init(days: [StatsDay], typingWpm: Double) {
        words = days.reduce(0) { $0 + $1.words }
        chars = days.reduce(0) { $0 + $1.chars }
        sessions = days.reduce(0) { $0 + $1.sessions }
        spokenSeconds = days.reduce(0) { $0 + $1.spokenSeconds }
        daysUsed = Set(days.map(\.day)).count

        let spokenMinutes = spokenSeconds / 60
        averageWpm = spokenMinutes > 0 ? Double(words) / spokenMinutes : 0
        // Clamped: someone dictating slower than they type has "saved" nothing,
        // and a negative headline number is noise rather than insight.
        secondsSaved = max(0, Double(words) / typingWpm * 60 - spokenSeconds)

        let latchedSessions = days.reduce(0) { $0 + $1.latched }
        latchedShare = sessions > 0 ? Double(latchedSessions) / Double(sessions) : 0

        var byModel: [String: StatsDay] = [:]
        for row in days {
            if var existing = byModel[row.model] {
                existing.merge(row)
                byModel[row.model] = existing
            } else {
                byModel[row.model] = row
            }
        }
        models = byModel.values
            .sorted { $0.words > $1.words }
            .map {
                Model(
                    model: $0.model,
                    words: $0.words,
                    sessions: $0.sessions,
                    averageProcessSeconds: $0.processSamples > 0
                        ? $0.processSeconds / Double($0.processSamples)
                        : nil
                )
            }
    }
}
