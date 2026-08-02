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

    private var transcriber: Transcriber?
    private var monitor: HotkeyMonitor?
    private let capture = AudioCapture()
    private var overlay: RecordingOverlay?
    private var menuBar: MenuBarController?
    private var history: TranscriptStore?
    private var stats: StatsStore?
    private var wordlist: Wordlist
    private var cleaner: TextCleaner?
    /// Built per squawk rather than held: the provider, model and key can all
    /// change between one recording and the next.
    private var squawkContext: Task<ScreenContext?, Never>?

    private var isLatched = false
    private var isRecording = false
    /// Which key started the recording in flight. Read again at the end of it,
    /// so a settings change mid-utterance can't reroute audio that was captured
    /// under the other mode.
    private var mode: DictationMode = .dictate
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
        context.startOverlayPreview = { [weak self] sensitivity in
            self?.startOverlayPreview(sensitivity: sensitivity)
        }
        context.updateOverlayPreview = { [weak self] sensitivity in
            self?.updateOverlayPreview(sensitivity: sensitivity)
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
        if new.hotkey != old.hotkey || new.latch != old.latch || new.squawk != old.squawk {
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

        context.engineStatus = .loading(model.isLocal ? "Loading \(model.id)" : "Checking \(model.id)")
        menuBar?.setEngine(.loading)

        let transcriber = makeTranscriber(for: model)
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
                    // A remote model's only warm-up is "is there a key?", and
                    // naming that is far more use than "failed to load" — the
                    // fix is in the Accounts pane, not the Models pane.
                    let detail = (error as? TranscriberError)?.description
                    self.context.engineStatus = .failed(
                        model.isLocal ? "\(model.id) failed to load" : (detail ?? "\(model.id) unavailable")
                    )
                    self.menuBar?.setEngine(.failed)
                    FileHandle.standardError.write(Data("warmup failed: \(detail ?? "\(error)")\n".utf8))
                }
            }
        }
    }

    /// The one place a registry entry becomes a running engine.
    private func makeTranscriber(for model: TranscriptionModel) -> Transcriber {
        switch model.engine {
        case .parakeet:
            return ParakeetTranscriber(model: model, language: resolveLanguage())
        case .openai:
            return OpenAITranscriber(model: model)
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
            overlay.setSensitivity(settings.overlay.sensitivity)
        } else {
            overlay = RecordingOverlay(sensitivity: settings.overlay.sensitivity)
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

        var bindings: [(DictationMode, Hotkey)] = [(.dictate, hotkey)]
        if settings.squawk.enabled {
            // A squawk key that collides with the dictation key is dropped
            // rather than fatal: dictation is the thing you can't lose, and the
            // settings pane says the same thing where someone can fix it.
            if settings.squawk.isUsable(alongside: hotkey) {
                bindings.append((.squawk, settings.squawk.hotkey))
            } else {
                FileHandle.standardError.write(Data(
                    ("squawk hotkey \(settings.squawk.hotkey.displayLabel) can't be used "
                        + "alongside \(hotkey.displayLabel) — pick another in settings\n").utf8
                ))
            }
        }

        let monitor = HotkeyMonitor(hotkeys: bindings, config: settings.latch, debug: debugHotkey)
        do {
            try monitor.start { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            self.monitor = monitor
            monitorFailure = nil
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
            let latchHint = settings.latch.enabled ? " · double-tap for hands-free" : ""
            let listening = bindings
                .map { "\($0.1.displayName) to \($0.0 == .dictate ? "dictate" : "squawk")" }
                .joined(separator: " · ")
            FileHandle.standardError.write(Data(
                "listening on \(listening)\(latchHint)\n".utf8
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
        case .begin(let mode):
            beginRecording(mode)
        case .latched:
            // Only meaningful over a recording that actually started. A capture
            // that failed to open leaves the monitor's state machine running,
            // and latching on it would strand the pill in "hands-free".
            guard isRecording else { return }
            isLatched = true
            FileHandle.standardError.write(Data("🔒 hands-free · tap to stop\n".utf8))
            overlay?.show(.latched, mode: mode)
            menuBar?.setState(.latched)
        case .cancelled:
            _ = capture.stop()
            isRecording = false
            isLatched = false
            squawkContext?.cancel()
            squawkContext = nil
            FileHandle.standardError.write(Data("✗ cancelled\n".utf8))
            overlay?.hide()
            menuBar?.setState(.idle)
        case .end:
            endRecording()
        }
    }

    private func beginRecording(_ mode: DictationMode) {
        // A preview owns the same microphone and the same pill. Dictation wins.
        endOverlayPreview()
        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            return
        }
        self.mode = mode
        isRecording = true
        isLatched = false
        // Read the screen now, while the user is still talking, rather than
        // after they stop: the walk costs a few hundred milliseconds, and this
        // is the only place in the whole flow where they are free. It also
        // snapshots the screen as it was when they reached for the key, which
        // is the thing they were looking at when they decided what to say.
        if mode == .squawk {
            startContextCapture()
        }
        FileHandle.standardError.write(Data(
            (mode == .squawk ? "🦜 squawking\n" : "● recording\n").utf8
        ))
        overlay?.show(.recording, mode: mode)
        menuBar?.setState(.recording)
    }

    private func endRecording() {
        guard isRecording else { return }
        let samples = capture.stop()
        isRecording = false
        let wasLatched = isLatched
        isLatched = false

        overlay?.show(.transcribing, mode: mode)
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
            squawkContext?.cancel()
            squawkContext = nil
            overlay?.hide()
            menuBar?.setState(.idle)
            return
        }

        if mode == .squawk {
            endSquawk(samples: samples, seconds: seconds, latched: wasLatched, transcriber: transcriber)
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
            // The wordlist's vocabulary, headed upstream this time: the same
            // terms the cleaner is told to preserve are the ones the API
            // decoder is told to listen for.
            transcription: TranscriptionContext(
                vocabulary: wordlist.vocabulary,
                languages: settings.languages
            ),
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

    // MARK: - Squawk

    /// Kicks the accessibility walk off on a background thread. Every AX call
    /// is IPC into another app's runloop, so this must never be on main —
    /// one wedged app would otherwise freeze the pill, the hotkey and the
    /// menu bar along with it.
    private func startContextCapture() {
        squawkContext?.cancel()
        guard let target = AppTarget.frontmost() else {
            squawkContext = nil
            return
        }
        let limits = settings.squawk.context.limits
        let readWindow = settings.squawk.context.readWindow
        let excluded = settings.squawk.isExcluded(bundleID: target.bundleID)

        squawkContext = Task.detached(priority: .userInitiated) {
            guard !excluded else {
                return ScreenContext.skipped(
                    .excludedApp, app: target.name, bundleID: target.bundleID
                )
            }
            var limits = limits
            // "Selection and focused field only" is the same walk with no
            // budget for the window text.
            if !readWindow { limits.maxCharacters = 0 }
            return ScreenReader.capture(target, limits: limits)
        }
    }

    private func endSquawk(
        samples: [Float],
        seconds: Double,
        latched: Bool,
        transcriber: Transcriber
    ) {
        let squawk = settings.squawk
        let client: LLMClient
        switch makeLLMClient(
            provider: squawk.provider,
            model: squawk.model,
            reasoningEffort: squawk.reasoningEffort.rawValue
        ) {
        case .success(let made):
            client = made
        case .failure(let error):
            FileHandle.standardError.write(Data("squawk unavailable — \(error)\n".utf8))
            squawkContext?.cancel()
            squawkContext = nil
            overlay?.hide()
            menuBar?.setState(.idle)
            return
        }

        let pipeline = SquawkPipeline(
            transcriber: transcriber,
            wordlist: wordlist,
            client: client,
            settings: squawk,
            store: history,
            stats: stats,
            transcription: TranscriptionContext(
                vocabulary: wordlist.vocabulary,
                languages: settings.languages
            ),
            languages: LanguageSelection.displayNames(settings.languages),
            modelID: transcriber.modelID
        )

        let contextTask = squawkContext
        squawkContext = nil

        Task { [weak self] in
            let context = await contextTask?.value ?? nil
            let output = await pipeline.process(
                samples: samples,
                seconds: seconds,
                latched: latched,
                context: context
            )
            await MainActor.run { [weak self] in
                if let output {
                    // Typing over a selection replaces it, and so does pasting
                    // over one — so `.replace` needs nothing extra here beyond
                    // not having disturbed the selection in the meantime.
                    TextInjector.put(output.text)
                }
                guard let self, !self.isRecording, !self.isPreviewing else { return }
                self.overlay?.hide()
                self.menuBar?.setState(.idle)
            }
        }
    }

    // MARK: - Overlay preview

    private func startOverlayPreview(sensitivity: Double) {
        guard !isRecording else { return }
        // The preview has to work even with the pill switched off — that is one
        // of the things someone in the Appearance pane may be deciding.
        if overlay == nil {
            overlay = RecordingOverlay(sensitivity: sensitivity)
        }
        overlay?.setSensitivity(sensitivity)
        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("preview capture failed: \(error)\n".utf8))
            return
        }
        isPreviewing = true
        // Sensitivity is a dictation-side concern and the meter behaves the
        // same either way, so the preview always wears the dictation pill.
        overlay?.show(.recording, mode: .dictate)
    }

    private func updateOverlayPreview(sensitivity: Double) {
        guard isPreviewing else { return }
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
