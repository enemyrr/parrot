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
    private let systemMute = SystemAudioMute()
    private var overlay: RecordingOverlay?
    private var menuBar: MenuBarController?
    private var history: TranscriptStore?
    private var stats: StatsStore?
    private var wordlist: Wordlist
    private var shortcuts: ShortcutExpander
    private var cleaner: TextCleaner?
    /// Built per squawk rather than held: the provider, model and key can all
    /// change between one recording and the next.
    private var squawkContext: Task<ScreenContext?, Never>?
    /// The names in the window the dictation in flight is headed for, read while
    /// the user is still talking. Nil whenever integrations are off, no
    /// integration claims the app, or this one has given up on it.
    private var rosterTask: Task<AppRoster, Never>?
    /// Whose window `rosterTask` is reading. The monitor keys its give-up count
    /// on it, so an app that restarts into a version that works gets another go.
    private var rosterPID: pid_t?
    /// Which integrations are currently working. Shared with the settings
    /// window, which is the only place a user can see any of this.
    private let integrations = IntegrationMonitor.shared
    /// Which app the recording in flight is headed for, read when the key went
    /// down. Dictation's half of app matching, and the id is all of it — the
    /// window's *contents* are never read on this path, integrations or not.
    private var frontBundleID: String?

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
        self.shortcuts = ShortcutExpander(shortcuts: store.settings.shortcuts)
    }

    /// The dictionary's terms plus every shortcut trigger, for the transcriber
    /// and the cleaner. Both halves have to be heard right and left alone: a
    /// trigger the cleaner rewrote is a shortcut that silently stops firing.
    private var spokenVocabulary: [String] {
        wordlist.vocabulary + shortcuts.triggers
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
        // First, before any of the below can persist a settings change: an
        // upgrade has to be told apart from a first run, and a stored blob is
        // the only evidence of one.
        SettingsStore.seedOnboardingForExistingInstall()

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
        // A file transcription borrows the engine that is already loaded rather
        // than loading a second copy of the same model. It serializes against
        // dictation — the transcriber is an actor — so a long file makes the
        // next hotkey press wait its turn, which is the right way round: the
        // file was asked for explicitly and finishes in a fraction of its own
        // length.
        FileTranscriptionJob.shared.liveEngine = { [weak self] in self?.transcriber }

        context.startOverlayPreview = { [weak self] sensitivity in
            self?.startOverlayPreview(sensitivity: sensitivity)
        }
        context.updateOverlayPreview = { [weak self] sensitivity in
            self?.updateOverlayPreview(sensitivity: sensitivity)
        }
        context.endOverlayPreview = { [weak self] in
            self?.endOverlayPreview()
        }

        capture.preferredDeviceUID = settings.audio.inputDeviceUID
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
            settings: store,
            store: history
        )

        // Before the engine and the monitor, so the two things most likely to
        // fail on a fresh Mac — no model, no accessibility — find the setup
        // window already up and say their piece inside it rather than opening a
        // settings window over the top of it.
        if !SettingsStore.hasCompletedOnboarding {
            OnboardingWindowController.shared.show(store: store, catalog: catalog, context: context)
        }

        loadEngine()
        startMonitor()
    }

    func stop() {
        // First: a daemon that exits mid-recording must not leave the Mac
        // silent behind it, and there is nobody left to put it back afterwards.
        systemMute.restore()
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
        if new.audio != old.audio {
            capture.preferredDeviceUID = new.audio.inputDeviceUID
            // Switching it off while a hands-free recording is running has to
            // give the audio back now rather than at the end of the sentence.
            if !new.audio.muteWhileDictating {
                systemMute.restore()
            }
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
        if new.shortcuts != old.shortcuts {
            shortcuts = ShortcutExpander(shortcuts: new.shortcuts)
        }
        if new.integrations != old.integrations {
            // Anything the user changed here is a reason to give an integration
            // parrot had given up on another chance — including switching one
            // back on, which is exactly what someone does after fixing whatever
            // made it come back empty.
            integrations.reset()
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

        let transcriber = makeEngine(for: model)
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

    /// The daemon's engine, from the shared factory. The language hint is
    /// resolved only for the engine that takes one: `resolveLanguage` logs what
    /// it decided, and it has nothing to say about a cloud model that never
    /// sees it.
    private func makeEngine(for model: TranscriptionModel) -> Transcriber {
        makeTranscriber(for: model, language: model.engine == .parakeet ? resolveLanguage() : nil)
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
        guard !overlaySuppressed else {
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
            systemMute.restore()
            isRecording = false
            isLatched = false
            squawkContext?.cancel()
            squawkContext = nil
            rosterTask?.cancel()
            rosterTask = nil
            rosterPID = nil
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
        // After the capture opened, not before: a start that throws would
        // otherwise silence the Mac for a recording that never happened.
        if settings.audio.muteWhileDictating {
            systemMute.mute()
        }
        // Read the screen now, while the user is still talking, rather than
        // after they stop: the walk costs a few hundred milliseconds, and this
        // is the only place in the whole flow where they are free. It also
        // snapshots the screen as it was when they reached for the key, which
        // is the thing they were looking at when they decided what to say.
        frontBundleID = nil
        rosterTask?.cancel()
        rosterTask = nil
        if mode == .squawk {
            startContextCapture()
        } else {
            // Cheap — the frontmost app, not a walk of its window. Read here
            // rather than at the end so it is the app they were in when they
            // reached for the key, not whatever they alt-tabbed to while the
            // model was thinking.
            let target = AppTarget.frontmost()
            frontBundleID = target?.bundleID
            // The one thing on the dictation path that does walk the window,
            // and only for the names in it. Off unless asked for.
            if let target { startRosterCapture(target) }
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
        // With the mic, not with the text: transcription and cleanup can take
        // seconds, and there is no reason for the Mac to stay silent through
        // them once nothing is listening.
        systemMute.restore()
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

        let rosterTask = self.rosterTask
        let rosterPID = self.rosterPID
        let frontBundleID = self.frontBundleID
        self.rosterTask = nil
        self.rosterPID = nil

        // `Task {}` in a main-actor method inherits the main actor, so the
        // pipeline is still built there — after the roster lands, which is the
        // only reason this moved inside. The walk was kicked off when the key
        // went down and has had the whole utterance to finish; awaiting it here
        // costs nothing in the ordinary case and bounds itself by its own
        // deadline in the bad one.
        Task { [weak self] in
            let roster = await rosterTask?.value
            guard let self else { return }
            if let roster, let id = roster.integrationID, let rosterPID {
                self.integrations.record(roster, integrationID: id, pid: rosterPID)
                FileHandle.standardError.write(Data("integration: \(roster.summary)\n".utf8))
            }
            let tagger = EntityTagger(roster: roster, settings: self.settings.integrations)

            // Built per dictation rather than held as a field: every component
            // it names can be swapped by a settings change, and a stale pipeline
            // would quietly keep using the old one.
            let pipeline = DictationPipeline(
                transcriber: transcriber,
                wordlist: self.wordlist,
                shortcuts: self.shortcuts,
                tagger: tagger,
                cleaner: self.cleaner,
                cleanup: self.settings.cleanup,
                style: self.settings.style,
                bundleID: frontBundleID,
                store: self.history,
                languages: LanguageSelection.displayNames(self.settings.languages),
                // The vocabulary, headed upstream this time: the same terms the
                // cleaner is told to preserve are the ones the API decoder is
                // told to listen for — and the names off the screen ride along,
                // because a tag rule only fires if the decoder heard the name.
                transcription: TranscriptionContext(
                    vocabulary: self.spokenVocabulary + tagger.vocabulary,
                    languages: self.settings.languages
                ),
                stats: self.stats,
                // The transcriber in hand, not the selected id: choosing a model
                // that isn't downloaded yet keeps the previous one running, and
                // history and stats have to name the one that did the work.
                modelID: transcriber.modelID
            )

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

    // MARK: - Integrations

    /// Kicks off the roster walk, if there is anything to walk for.
    ///
    /// Every guard here is a reason not to spend the walk, checked in the order
    /// that costs least: the switch, then the app table, then this app's own
    /// switch, then whether the monitor has already given up on it. The last one
    /// is the failsafe — an integration that keeps coming back empty stops being
    /// asked, rather than quietly costing a few hundred milliseconds of every
    /// dictation forever.
    private func startRosterCapture(_ target: AppTarget) {
        guard settings.integrations.doesAnything else { return }
        guard let integration = AppIntegrations.integration(for: target.bundleID) else { return }
        guard settings.integrations.isEnabled(integration.id) else { return }
        guard integrations.shouldRead(integration, pid: target.pid) else { return }

        rosterPID = target.pid
        // Detached for the same reason squawk's walk is: every AX call is IPC
        // into another app's runloop, and one wedged app must not take the
        // hotkey and the pill down with it.
        rosterTask = Task.detached(priority: .userInitiated) {
            RosterReader.read(target, integration: integration)
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
            shortcuts: shortcuts,
            client: client,
            settings: squawk,
            style: settings.style,
            store: history,
            stats: stats,
            transcription: TranscriptionContext(
                vocabulary: spokenVocabulary,
                languages: settings.languages
            ),
            languages: LanguageSelection.displayNames(settings.languages),
            modelID: transcriber.modelID,
            onThinking: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isRecording, !self.isPreviewing else { return }
                    self.overlay?.show(.thinking, mode: .squawk)
                }
            }
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
        // The setup window is already covering both of these, in order and with
        // a Continue button. A settings window over it would be two setups at
        // once, disagreeing about which step you are on.
        guard !OnboardingWindowController.shared.isOpen else { return }
        guard !openedWindowForSetup else { return }
        openedWindowForSetup = true
        SettingsWindowController.shared.show(pane: pane)
    }
}
