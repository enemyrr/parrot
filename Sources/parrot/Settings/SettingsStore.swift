import Combine
import Foundation

/// The one place settings are read from and written to.
///
/// Backed by `UserDefaults` under an explicit suite rather than
/// `UserDefaults.standard`: parrot runs both as a bare binary on `$PATH` and as
/// `parrot.app`, and the standard suite would give those two different
/// preference domains — the same user's settings would vanish depending on how
/// they launched it.
///
/// The whole `Settings` value is stored as one JSON blob under a single key.
/// Writes are therefore atomic, and a reader never sees half of a change.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // Nonisolated so the CLI's synchronous read path can reach them: the class
    // is main-actor, but these two are constants and the storage they name is
    // thread-safe on its own.
    nonisolated static let suiteName = "com.digimata.parrot"
    nonisolated private static let key = "settings"

    /// Called after every persisted change with (old, new). The daemon uses it
    /// to reconfigure only the parts that actually differ.
    var onChange: ((Settings, Settings) -> Void)?

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            Self.persist(settings)
            onChange?(oldValue, settings)
        }
    }

    private init() {
        settings = Self.loadStored() ?? Settings.default
    }

    /// Overwrite everything, e.g. from the migrator or a "restore defaults"
    /// button. Goes through `settings` so observers and persistence both fire.
    func replace(with new: Settings) {
        settings = new
    }

    func resetToDefaults() {
        replace(with: .default)
    }

    // MARK: - Storage

    /// Both launch styles have to land on the same `com.digimata.parrot.plist`.
    ///
    /// As a bare binary on `$PATH` there is no bundle identifier, so the
    /// standard domain is keyed off the executable name and the explicit suite
    /// is what points it at the right file. Inside `parrot.app` the bundle
    /// identifier *is* that suite, and `UserDefaults` refuses that combination
    /// — it returns nil and logs "using your own bundle identifier as a suite
    /// name does not make sense" — because the standard domain already is that
    /// suite. So each case gets the one that actually works.
    nonisolated private static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Read the persisted settings without touching the main actor — the CLI
    /// subcommands need this and none of them run an app.
    ///
    /// The legacy import runs here rather than only in `run`/`settings`: a user
    /// upgrading from a `config.toml` build may well type `parrot doctor` or
    /// `parrot stats` first, and those would otherwise report on factory
    /// defaults rather than on the settings they actually have. Costs one
    /// `fileExists` once anything has been stored.
    nonisolated static func current() -> Settings {
        LegacyConfigMigration.runIfNeeded()
        return loadStored() ?? .default
    }

    nonisolated private static func loadStored() -> Settings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // Nothing readable to fall back to, and refusing to launch over a
            // corrupt preferences blob would be worse than starting fresh.
            FileHandle.standardError.write(Data(
                "settings could not be read (\(error)); using defaults\n".utf8
            ))
            return nil
        }
    }

    nonisolated static func persist(_ settings: Settings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(settings), forKey: key)
        } catch {
            FileHandle.standardError.write(Data("settings could not be saved: \(error)\n".utf8))
        }
    }

    /// True once anything has been written — i.e. this isn't a first run.
    nonisolated static var hasStoredSettings: Bool {
        defaults.data(forKey: key) != nil
    }
}
