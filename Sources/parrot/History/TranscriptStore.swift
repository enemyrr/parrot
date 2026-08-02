import Foundation

struct TranscriptEntry: Codable {
    let at: Date
    /// Straight off the ASR engine, before wordlist and cleanup. For a squawk
    /// this is the instruction, not the answer.
    let raw: String
    /// What actually got typed.
    let text: String
    let model: String
    let seconds: Double
    let latched: Bool
    let cleaned: Bool
    /// Which key produced this. Absent in entries written before squawk
    /// existed, which are all dictation.
    let mode: DictationMode

    init(
        at: Date,
        raw: String,
        text: String,
        model: String,
        seconds: Double,
        latched: Bool,
        cleaned: Bool,
        mode: DictationMode = .dictate
    ) {
        self.at = at
        self.raw = raw
        self.text = text
        self.model = model
        self.seconds = seconds
        self.latched = latched
        self.cleaned = cleaned
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        raw = try c.decode(String.self, forKey: .raw)
        text = try c.decode(String.self, forKey: .text)
        model = try c.decode(String.self, forKey: .model)
        seconds = try c.decode(Double.self, forKey: .seconds)
        latched = try c.decode(Bool.self, forKey: .latched)
        cleaned = try c.decode(Bool.self, forKey: .cleaned)
        mode = try c.decodeIfPresent(DictationMode.self, forKey: .mode) ?? .dictate
    }
}

/// Append-only JSONL log of everything dictated.
///
/// JSONL rather than SQLite: at ~200 bytes an entry, the 5000-entry cap is
/// about a megabyte, so a full in-memory scan for search is instant, there's
/// no schema to migrate, and the file stays greppable with ordinary tools.
final class TranscriptStore {
    private let url: URL
    private let maxEntries: Int
    private let enabled: Bool
    /// Shared across instances: the settings window runs inside the daemon and
    /// builds its own store to clear or prune from, so a per-instance lock
    /// wouldn't stand between those and an append in flight.
    private static let lock = NSLock()
    private var lock: NSLock { Self.lock }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(settings: HistorySettings, url: URL = ParrotPaths.historyFile) {
        self.url = url
        self.maxEntries = settings.maxEntries
        self.enabled = settings.enabled
    }

    func append(_ entry: TranscriptEntry) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            guard var line = try? Self.encoder.encode(entry) else { return }
            line.append(0x0A)  // newline
            try ensureFile()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            FileHandle.standardError.write(Data("  history write failed: \(error)\n".utf8))
        }
    }

    /// Newest first.
    func all() -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().reversed()
    }

    /// Newest first, decoding only the last `count` lines.
    ///
    /// The menu bar calls this every time the Recent submenu opens. Going
    /// through `all()` meant JSON-decoding 5000 entries to show ten of them;
    /// reading the ~1 MB file itself is cheap, the decoding wasn't. A line
    /// that fails to decode still consumes a slot — consistent with
    /// `loadUnlocked`, so a truncated final write costs one row, not the file.
    func recent(_ count: Int) -> [TranscriptEntry] {
        guard count > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoded = data.split(separator: 0x0A).suffix(count)
            .compactMap { try? Self.decoder.decode(TranscriptEntry.self, from: Data($0)) }
        return decoded.reversed()
    }

    func search(_ query: String, limit: Int) -> [TranscriptEntry] {
        let needle = query.lowercased()
        return all()
            .filter { $0.text.lowercased().contains(needle) || $0.raw.lowercased().contains(needle) }
            .prefix(limit)
            .map { $0 }
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Data().write(to: url, options: .atomic)
    }

    /// Trim the log to `maxEntries`, oldest first. Called once at startup so
    /// the file can't grow without bound across years of dictation.
    func prune() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let entries = loadUnlocked()
        guard entries.count > maxEntries else { return }
        let kept = entries.suffix(maxEntries)
        var out = Data()
        for entry in kept {
            guard var line = try? Self.encoder.encode(entry) else { continue }
            line.append(0x0A)
            out.append(line)
        }
        do {
            try out.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(Data("  history prune failed: \(error)\n".utf8))
        }
    }

    var path: String { url.path }

    // MARK: - Private

    /// Oldest first, skipping any line that fails to decode — a truncated
    /// write shouldn't cost the user their whole history.
    private func loadUnlocked() -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? Self.decoder.decode(TranscriptEntry.self, from: Data($0))
        }
    }

    private func ensureFile() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fm.fileExists(atPath: url.path) {
            // 0600 from the start — this file holds everything ever dictated,
            // including anything typed into the wrong window.
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }
}
