import Foundation

struct TranscriptEntry: Codable {
    let at: Date
    /// Straight off the ASR engine, before wordlist and cleanup.
    let raw: String
    /// What actually got typed.
    let text: String
    let model: String
    let seconds: Double
    let latched: Bool
    let cleaned: Bool
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
    private let lock = NSLock()

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

    init(config: HistoryConfig, url: URL = ParrotPaths.historyFile) {
        self.url = url
        self.maxEntries = config.maxEntries
        self.enabled = config.enabled
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

    func recent(_ count: Int) -> [TranscriptEntry] {
        Array(all().prefix(count))
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
