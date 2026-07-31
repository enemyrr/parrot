import AppKit
import ApplicationServices
import FluidAudio
import Foundation

/// The running daemon, as one object.
///
/// Everything used to be assembled once inside `Run.run()` and then frozen:
/// changing a setting meant editing a file and restarting. Now the settings
/// window writes into `SettingsStore` and this class reacts, rebuilding only
/// the pieces a given change actually touches — swapping the model reloads the
/// engine, but changing the meter sensitivity doesn't.
///
/// Everything here is main-actor. The hotkey tap already delivers on the main
/// runloop and the overlay is a window, so the alternative would be hopping
/// queues for no benefit; the only genuinely concurrent work — model load and
/// transcription — lives behind an actor.
@MainActor
final class DictationController {
    private let store: SettingsStore
    private let catalog: ModelCatalog
    private let context: SettingsContext

    private var settings: Settings

    private var transcriber: ParakeetTranscriber?
    private var monitor: HotkeyMonitor?
    private let capture = AudioCapture()
    private var overlay: RecordingOverlay?
    private var menuBar: MenuBarController?
    private var history: TranscriptStore?
    private var stats: StatsStore?
    private var wordlist: Wordlist
    private var cleaner: TextCleaner?

    private var isLatched = false
    private var isRecording = false
    /// Lives on the context so the Appearance pane reads the real state rather
    /// than its own guess at it.
    private var isPreviewing: Bool {
        get { context.isPreviewing }
        set { context.isPreviewing = newValue }
    }
    /// Warm-ups are generation-tagged: switching models mid-load has to leave
    /// the superseded one unable to report itself ready.
    private var engineGeneration = 0
    private var accessibilityPoll: Timer?
    private var openedWindowForSetup = false
    /// Why the hotkey isn't listening, when it isn't. The menu bar has one
    /// status slot for both the engine and the monitor, so a warm-up finishing
    /// must not paint over "accessibility not granted".
    private var monitorFailure: MenuBarController.Engine?

    /// Set by `Run` from `--debug-hotkey`; not a user setting.
    var debugHotkey = false
    /// Set by `Run` from `--no-overlay`, and beats the stored setting.
    var overlaySuppressed = false
    /// Set by `Run` from `--dump-wav`.
    var dumpWav = false

    /// No default arguments: a default expression is evaluated outside the
    /// type's isolation, so `.shared` in one is a main-actor access from a
    /// nonisolated context. The caller already has the actor.
    init(store: SettingsStore, catalog: ModelCatalog, context: SettingsContext) {
        self.store = store
        self.catalog = catalog
        self.context = context
        self.settings = store.settings
        self.wordlist = Wordlist(settings: store.settings.wordlist)
    }

    convenience init() {
        self.init(
            store: .shared,
            catalog: .shared,
            context: SettingsWindowController.shared.context
        )
    }

    // MARK: - Lifecycle

    func start() {
        store.onChange = { [weak self] old, new in
            self?.apply(old: old, new: new)
        }
        // Compared against the *resolved* model, not the stored id: a settings
        // blob naming a retired model resolves to the fallback, and it is the
        // fallback that gets downloaded and finishes here.
        catalog.onInstalled = { [weak self] model in
            guard let self, model.id == self.settings.resolvedModel.id else { return }
            self.loadEngine()
        }
        catalog.onFailed = { [weak self] model, reason in
            guard let self, model.id == self.settings.resolvedModel.id else { return }
            self.context.engineStatus = .failed(reason)
            self.menuBar?.setEngine(.failed)
        }
        context.startOverlayPreview = { [weak self] style, sensitivity in
            self?.startOverlayPreview(style: style, sensitivity: sensitivity)
        }
        context.updateOverlayPreview = { [weak self] style, sensitivity in
            self?.updateOverlayPreview(style: style, sensitivity: sensitivity)
        }
        context.endOverlayPreview = { [weak self] in
            self?.endOverlayPreview()
        }

        capture.onLevel = { [weak self] level in
            // Hops to the main actor inside pushLevel; the audio thread must
            // not block here.
            Task { @MainActor in self?.overlay?.pushLevel(level) }
        }

        rebuildOverlay()
        rebuildStores(prune: true)
        rebuildCleaner()
        menuBar = MenuBarController(
            openSettings: { SettingsWindowController.shared.show(pane: $0) },
            store: history
        )

        loadEngine()
        startMonitor()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
    }

    // MARK: - Settings changes

    private func apply(old: Settings, new: Settings) {
        settings = new

        if new.model != old.model || new.languages != old.languages {
            loadEngine()
        }
        if new.hotkey != old.hotkey || new.latch != old.latch {
            restartMonitor()
        }
        if new.cleanup != old.cleanup {
            rebuildCleaner()
        }
        if new.wordlist != old.wordlist {
            wordlist = Wordlist(settings: new.wordlist)
        }
        if new.history != old.history || new.stats != old.stats {
            rebuildStores()
            menuBar?.setHistoryStore(history)
        }
        if new.overlay != old.overlay {
            rebuildOverlay()
        }
    }

    // MARK: - Engine

    private func loadEngine() {
        engineGeneration += 1
        let generation = engineGeneration
        let model = settings.resolvedModel

        guard model.isDownloaded else {
            context.engineStatus = .loading("Downloading \(model.id)")
            menuBar?.setEngine(.loading)
            // Auto-start rather than wait to be asked: the old build downloaded
            // on first launch with no prompt at all, and there is nothing parrot
            // can do without a model. The difference now is that it happens
            // somewhere with a progress bar and a cancel button.
            if !catalog.state(for: model).isDownloading {
                catalog.download(model)
            }
            showSetupWindowOnce(pane: .models)
            return
        }

        context.engineStatus = .loading("Loading \(model.id)")
        menuBar?.setEngine(.loading)

        let language = resolveLanguage()
        let transcriber = ParakeetTranscriber(model: model, language: language)
        self.transcriber = transcriber

        Task { [weak self] in
            do {
                try await transcriber.warmUp()
                await MainActor.run { [weak self] in
                    guard let self, self.engineGeneration == generation else { return }
                    self.context.engineStatus = .ready(model.id)
                    // A ready model doesn't make an unregistered hotkey work,
                    // and the monitor's failure is the one the user can act on.
                    self.menuBar?.setEngine(self.monitorFailure ?? .ready)
                    // Success marker so `parrot status` doesn't keep reporting a
                    // warm-up failure the daemon has since recovered from.
                    FileHandle.standardError.write(Data("model ready: \(model.id)\n".utf8))
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.engineGeneration == generation else { return }
                    self.context.engineStatus = .failed("\(model.id) failed to load")
                    self.menuBar?.setEngine(.failed)
                    FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
                }
            }
        }
    }

    /// Resolves the language hint, reporting anything odd to the log. The
    /// settings window shows the same finding as a check, so this is only for
    /// someone watching `parrot logs`.
    private func resolveLanguage() -> Language? {
        switch LanguageSelection.resolve(settings.languages) {
        case .filter(let resolved):
            let script = LanguageSelection.describe(resolved.script)
            let listed = settings.languages.joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "languages: \(listed) · restricting output to \(script) script\n".utf8
            ))
            return resolved
        case .unrestricted:
            return nil
        case .conflicting(let scripts):
            let joined = scripts.joined(separator: " + ")
            FileHandle.standardError.write(Data(
                "languages: \(joined) scripts configured together, so no filtering is applied\n".utf8
            ))
            return nil
        case .unknownCodes(let bad):
            FileHandle.standardError.write(Data(
                "unknown language code(s): \(bad.joined(separator: ", ")) — ignored\n".utf8
            ))
            return nil
        }
    }

    // MARK: - Components

    private func rebuildOverlay() {
        guard settings.overlay.enabled, !overlaySuppressed else {
            overlay?.hide()
            overlay = nil
            return
        }
        if let overlay {
            overlay.setStyle(settings.overlay.style)
            overlay.setSensitivity(settings.overlay.sensitivity)
        } else {
            overlay = RecordingOverlay(
                style: settings.overlay.style,
                sensitivity: settings.overlay.sensitivity
            )
        }
    }

    /// `prune` only at startup. Dragging the "keep at most" slider rebuilds the
    /// stores on every tick, and pruning there would delete transcripts as the
    /// thumb passed each value — irreversibly, while the user was still
    /// deciding.
    private func rebuildStores(prune: Bool = false) {
        history = settings.history.enabled ? TranscriptStore(settings: settings.history) : nil
        if prune { history?.prune() }
        stats = settings.stats.enabled ? StatsStore(settings: settings.stats) : nil
        stats?.backfillFromHistoryIfNeeded()
    }

    private func rebuildCleaner() {
        guard settings.cleanup.enabled else {
            cleaner = nil
            return
        }
        switch makeCleaner(for: settings.cleanup) {
        case .success(let c):
            cleaner = c
            FileHandle.standardError.write(Data("cleanup: \(c.name)\n".utf8))
            // `makeCleaner` defers key and model-availability checks to each
            // request, so a cleaner that will fail every dictation still builds
            // fine here. Doctor knows the difference; the log should say so
            // rather than let the first failure be the first anyone hears.
            if case .warn(let why) = DoctorReport.checkCleanup(settings).status {
                FileHandle.standardError.write(Data("cleanup warning — \(why)\n".utf8))
            }
        case .failure(let error):
            // Not fatal — dictation still works, just without cleanup.
            cleaner = nil
            FileHandle.standardError.write(Data("cleanup disabled — \(error)\n".utf8))
        }
    }

    // MARK: - Hotkey

    private func restartMonitor() {
        monitor?.stop()
        monitor = nil
        startMonitor()
    }

    private func startMonitor() {
        let hotkey = settings.hotkey
        guard hotkey.isUsable else {
            FileHandle.standardError.write(Data(
                "hotkey \(hotkey.displayLabel) can't be used — pick another in settings\n".utf8
            ))
            monitorFailure = .failed
            menuBar?.setEngine(.failed)
            return
        }
        let monitor = HotkeyMonitor(hotkey: hotkey, config: settings.latch, debug: debugHotkey)
        do {
            try monitor.start { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            self.monitor = monitor
            monitorFailure = nil
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
            let latchHint = settings.latch.enabled ? " · double-tap for hands-free" : ""
            FileHandle.standardError.write(Data(
                "listening on \(hotkey.displayName) hold\(latchHint)\n".utf8
            ))
        } catch HotkeyMonitor.HotkeyError.accessibilityDenied {
            FileHandle.standardError.write(Data(
                "accessibility not granted — the hotkey can't be registered\n".utf8
            ))
            monitorFailure = .needsPermission
            menuBar?.setEngine(.needsPermission)
            showSetupWindowOnce(pane: .permissions)
            waitForAccessibility()
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            monitorFailure = .failed
            menuBar?.setEngine(.failed)
        }
    }

    /// The grant lands in System Settings, in another process, and takes effect
    /// here the moment it does. Polling for it means the user never has to
    /// restart parrot to finish setup — which the old build did require, and
    /// which was the single most confusing thing about first run.
    private func waitForAccessibility() {
        guard accessibilityPoll == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.monitor == nil else { return }
                guard AXIsProcessTrusted() else { return }
                FileHandle.standardError.write(Data("accessibility granted — starting\n".utf8))
                self.startMonitor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoll = timer
    }

    // MARK: - Dictation

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .begin:
            beginRecording()
        case .latched:
            // Only meaningful over a recording that actually started. A capture
            // that failed to open leaves the monitor's state machine running,
            // and latching on it would strand the pill in "hands-free".
            guard isRecording else { return }
            isLatched = true
            FileHandle.standardError.write(Data("🔒 hands-free · tap to stop\n".utf8))
            overlay?.show(.latched)
            menuBar?.setState(.latched)
        case .cancelled:
            _ = capture.stop()
            isRecording = false
            isLatched = false
            FileHandle.standardError.write(Data("✗ cancelled\n".utf8))
            overlay?.hide()
            menuBar?.setState(.idle)
        case .end:
            endRecording()
        }
    }

    private func beginRecording() {
        // A preview owns the same microphone and the same pill. Dictation wins.
        endOverlayPreview()
        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            return
        }
        isRecording = true
        isLatched = false
        FileHandle.standardError.write(Data("● recording\n".utf8))
        overlay?.show(.recording)
        menuBar?.setState(.recording)
    }

    private func endRecording() {
        guard isRecording else { return }
        let samples = capture.stop()
        isRecording = false
        let wasLatched = isLatched
        isLatched = false

        overlay?.show(.transcribing)
        menuBar?.setState(.transcribing)

        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        FileHandle.standardError.write(Data(
            String(format: "○ captured %.2fs · rms %.3f\n", seconds, computeRMS(samples)).utf8
        ))

        if dumpWav, !samples.isEmpty {
            let path = "/tmp/parrot-last.wav"
            do {
                try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
            }
        }

        guard !samples.isEmpty, let transcriber else {
            overlay?.hide()
            menuBar?.setState(.idle)
            return
        }

        // Built per dictation rather than held as a field: every component it
        // names can be swapped by a settings change, and a stale pipeline would
        // quietly keep using the old one.
        let pipeline = DictationPipeline(
            transcriber: transcriber,
            wordlist: wordlist,
            cleaner: cleaner,
            cleanup: settings.cleanup,
            store: history,
            languages: LanguageSelection.displayNames(settings.languages),
            stats: stats,
            // The transcriber in hand, not the selected id: choosing a model
            // that isn't downloaded yet keeps the previous one running, and
            // history and stats have to name the one that did the work.
            modelID: transcriber.modelID
        )

        Task { [weak self] in
            let text = await pipeline.process(
                samples: samples,
                seconds: seconds,
                latched: wasLatched
            )
            await MainActor.run { [weak self] in
                if let text, !text.isEmpty {
                    TextInjector.inject(text)
                }
                // Cleanup can take seconds, and the next recording — or an
                // overlay preview — may already have started. Clearing the pill
                // then would hide a session that is still live.
                guard let self, !self.isRecording, !self.isPreviewing else { return }
                self.overlay?.hide()
                self.menuBar?.setState(.idle)
            }
        }
    }

    // MARK: - Overlay preview

    private func startOverlayPreview(style: OverlayStyle, sensitivity: Double) {
        guard !isRecording else { return }
        // The preview has to work even with the pill switched off — that is one
        // of the things someone in the Appearance pane may be deciding.
        if overlay == nil {
            overlay = RecordingOverlay(style: style, sensitivity: sensitivity)
        }
        overlay?.setStyle(style)
        overlay?.setSensitivity(sensitivity)
        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("preview capture failed: \(error)\n".utf8))
            return
        }
        isPreviewing = true
        overlay?.show(.recording)
    }

    private func updateOverlayPreview(style: OverlayStyle, sensitivity: Double) {
        guard isPreviewing else { return }
        overlay?.setStyle(style)
        overlay?.setSensitivity(sensitivity)
    }

    private func endOverlayPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        _ = capture.stop()
        overlay?.hide()
        // Put the overlay back the way the settings say it should be — the
        // preview may have created one that shouldn't exist, or changed the
        // look of one that should.
        rebuildOverlay()
    }

    // MARK: - First run

    /// Opens the settings window at most once per launch, and only when
    /// something is genuinely blocking. Reopening it on every retry would make
    /// a machine that never gets its permission grant unusable.
    private func showSetupWindowOnce(pane: SettingsPane) {
        guard !openedWindowForSetup else { return }
        openedWindowForSetup = true
        SettingsWindowController.shared.show(pane: pane)
    }
}
