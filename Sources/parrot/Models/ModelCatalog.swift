import FluidAudio
import Foundation

extension TranscriptionModel {
    /// FluidAudio's version tag for this entry. The registry stores the engine
    /// id as a string so the model list stays engine-agnostic; this is the one
    /// place that string is turned back into a FluidAudio type.
    var asrVersion: AsrModelVersion {
        (engineModelID ?? "").hasSuffix("v2") ? .v2 : .v3
    }

    var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: asrVersion)
    }

    /// A remote model is always "downloaded": there is nothing to fetch, and
    /// answering false would send the daemon into the download branch on every
    /// launch and park it there.
    var isDownloaded: Bool {
        guard isLocal else { return true }
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
}

/// What the Models pane knows about one model.
enum ModelState: Equatable {
    case notInstalled
    /// `fraction` is already folded through `WarmupProgressCurve`, so it only
    /// ever climbs. `phase` is a short verb: "preparing", "downloading"…
    case downloading(fraction: Double, phase: String)
    /// `bytes` is nil until the directory has been measured off the main thread.
    case installed(bytes: Int64?)
    case failed(String)
    /// Runs on someone else's machine, so none of the states above apply — it
    /// is a case of its own rather than a permanently-`.installed` model, so a
    /// switch that forgets about it fails to compile instead of offering a
    /// Delete button for files that don't exist.
    case remote

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Owns everything the settings window needs to say about models on disk:
/// which are installed, how much space each takes, and the progress of one
/// being fetched.
///
/// Downloading is deliberately not the transcriber's job. The daemon warms up
/// whichever model is *active*; this fetches any model the user points at,
/// including ones they aren't using yet, and it has to keep reporting progress
/// whether or not a settings window happens to be open.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var states: [String: ModelState] = [:]

    /// Fires when a model finishes downloading, so the daemon can warm up if
    /// the new arrival is the active one.
    var onInstalled: ((TranscriptionModel) -> Void)?

    /// Fires when a download ends without the model on disk. Without it a
    /// failed or cancelled fetch of the *active* model leaves the daemon
    /// reporting "Downloading …" forever, with nothing in flight.
    var onFailed: ((TranscriptionModel, String) -> Void)?

    private var tasks: [String: Task<Void, Never>] = [:]
    private var curves: [String: WarmupProgressCurve] = [:]
    private var reporters: [String: AsyncStream<DownloadProgress>.Continuation] = [:]

    private init() {
        refresh()
    }

    func state(for model: TranscriptionModel) -> ModelState {
        states[model.id] ?? .notInstalled
    }

    /// Re-read disk. Cheap — a handful of `fileExists` calls — except for the
    /// directory sizing, which is handed off and lands later.
    func refresh() {
        for model in ModelRegistry.shared {
            guard model.isLocal else {
                states[model.id] = .remote
                continue
            }
            // Never stomp a download in flight; disk says "not installed" for
            // the whole of one, which would flip the row back to a Download
            // button mid-fetch.
            guard !(states[model.id]?.isDownloading ?? false) else { continue }
            guard model.isDownloaded else {
                states[model.id] = .notInstalled
                continue
            }
            // Carry a size already measured. Dropping it would make every
            // reopen of the pane blank the Storage line and re-walk thousands
            // of files to learn the same number.
            if case .installed(let bytes) = states[model.id] {
                states[model.id] = .installed(bytes: bytes)
            } else {
                states[model.id] = .installed(bytes: nil)
            }
        }
        measureSizes()
    }

    // MARK: - Downloading

    func download(_ model: TranscriptionModel) {
        guard model.isLocal, tasks[model.id] == nil else { return }
        curves[model.id] = WarmupProgressCurve()
        states[model.id] = .downloading(fraction: 0, phase: "preparing")

        let version = model.asrVersion
        let id = model.id

        // Progress arrives on whatever thread FluidAudio is using. Hopping each
        // report to the main actor in its own `Task` would lose their order,
        // and the curve reads any decrease as "a new sub-operation started" —
        // one reordered pair and the bar jumps a whole segment ahead of the
        // real download. A stream has one consumer, so order survives the hop.
        let (progressStream, reporter) = AsyncStream<DownloadProgress>.makeStream()
        reporters[id] = reporter
        let onProgress: ProgressHandler = { progress in reporter.yield(progress) }
        Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.report(progress, for: id)
            }
        }

        tasks[id] = Task { [weak self] in
            do {
                // Load as well as fetch, discarding the result. CoreML's ANE
                // specialisation is cached per device on first load, so paying
                // for it here means the first dictation after a download isn't
                // the one that waits.
                _ = try await AsrModels.downloadAndLoad(
                    version: version,
                    progressHandler: onProgress
                )
                await MainActor.run { self?.finish(id, model: model) }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.fail(id, error, model: model)
                }
            }
        }
    }

    func cancelDownload(_ model: TranscriptionModel) {
        guard model.isLocal else { return }
        let wasDownloading = tasks[model.id] != nil
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        curves[model.id] = nil
        reporters[model.id]?.finish()
        reporters[model.id] = nil
        states[model.id] = model.isDownloaded ? .installed(bytes: nil) : .notInstalled
        measureSizes()
        if wasDownloading, !model.isDownloaded {
            onFailed?(model, "\(model.id) download cancelled")
        }
    }

    private func report(_ progress: DownloadProgress, for id: String) {
        guard var curve = curves[id] else { return }
        let fraction = curve.advance(to: progress.fractionCompleted)
        curves[id] = curve

        let phase: String
        switch progress.phase {
        case .listing:
            phase = "preparing"
        // A model already on disk reports nothing to fetch. Calling that
        // "downloading" would be a lie the user reads on every launch.
        case .downloading(_, let totalFiles):
            phase = totalFiles == 0 ? "loading" : "downloading"
        case .compiling:
            phase = "compiling"
        }
        states[id] = .downloading(fraction: fraction, phase: phase)
    }

    private func finish(_ id: String, model: TranscriptionModel) {
        tasks[id] = nil
        curves[id] = nil
        reporters[id]?.finish()
        reporters[id] = nil
        states[id] = .installed(bytes: nil)
        measureSizes()
        onInstalled?(model)
    }

    private func fail(_ id: String, _ error: Error, model: TranscriptionModel) {
        tasks[id] = nil
        curves[id] = nil
        reporters[id]?.finish()
        reporters[id] = nil
        let reason = Self.describe(error)
        states[id] = .failed(reason)
        onFailed?(model, reason)
    }

    /// `localizedDescription` on a `DownloadError` reads as "The operation
    /// couldn't be completed"; the enum's own text names the actual file.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Deleting

    /// Removes the model's cache directory. Throws rather than reporting into
    /// `states` — this one is user-initiated, so it gets an alert.
    func delete(_ model: TranscriptionModel) throws {
        guard model.isLocal else { return }
        cancelDownload(model)
        let directory = model.cacheDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        states[model.id] = .notInstalled
    }

    /// Every installed model's footprint, for the "reclaim space" line.
    var totalInstalledBytes: Int64 {
        states.values.reduce(into: 0) { total, state in
            if case .installed(let bytes) = state { total += bytes ?? 0 }
        }
    }

    // MARK: - Sizing

    /// Walking a CoreML bundle is thousands of `stat` calls, so it runs off the
    /// main thread and the row shows its size when the number arrives.
    private func measureSizes() {
        let pending = ModelRegistry.shared.filter { model in
            if case .installed(let bytes) = states[model.id] { return bytes == nil }
            return false
        }
        guard !pending.isEmpty else { return }
        let directories = pending.map { ($0.id, $0.cacheDirectory) }

        Task.detached(priority: .utility) { [weak self] in
            var measured: [String: Int64] = [:]
            for (id, url) in directories {
                measured[id] = Self.directorySize(url)
            }
            // Frozen into a `let` before it crosses to the main actor — handing
            // a still-mutable dictionary across is a data race the compiler is
            // right to object to. Hopping back via a method rather than an
            // inline `MainActor.run` for the same reason: a capture list nested
            // inside another closure's capture list is a mutable capture.
            let sizes = measured
            await self?.apply(sizes)
        }
    }

    private func apply(_ sizes: [String: Int64]) {
        for (id, bytes) in sizes where states[id]?.isInstalled == true {
            states[id] = .installed(bytes: bytes)
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            // Allocated rather than logical size: this number is answering
            // "how much space would deleting it give me back?".
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

extension Int64 {
    /// "461 MB" — decimal units, matching how Finder reports disk usage.
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
