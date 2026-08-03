import AppKit
import SwiftUI

/// The front page: what to press, what it has done for you, and what it typed.
///
/// It replaced a "General" pane of labelled rows. The one thing every user
/// needs — which key to hold — is the headline with the key drawn on it, then
/// the numbers, then the transcripts, because "what did I just dictate?" is the
/// question this window gets opened for. The settings themselves come last: each
/// is a row that states its current value and opens a sheet, so the answers stay
/// on this page and the machinery doesn't. Everything that is a dial rather than
/// a decision stays folded under Advanced.
struct HomePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext
    @StateObject private var launchAgent = LaunchAgentState()
    @StateObject private var stats = HomeStats()

    @State private var dialog: Dialog?
    @State private var confirmingResetStats = false
    /// Enumerating CoreAudio is a HAL round trip, so the row's summary is cached
    /// rather than recomputed on every redraw of the pane.
    @State private var microphone = "System Default"

    /// How the menu bar's "Models…" item and `parrot settings models` land on
    /// the model list now that it is a sheet rather than a pane. A binding, not
    /// a value: this pane is rebuilt on every visit, and consuming it once is
    /// what stops the sheet reappearing on the way back to Home.
    @Binding var openModels: Bool

    init(
        store: SettingsStore,
        catalog: ModelCatalog,
        context: SettingsContext,
        openModels: Binding<Bool> = .constant(false)
    ) {
        self.store = store
        self.catalog = catalog
        self.context = context
        _openModels = openModels
    }

    private enum Dialog: String, Identifiable {
        case shortcuts, languages, microphone, models
        var id: String { rawValue }
    }

    private var overlay: OverlaySettings { store.settings.overlay }
    /// The daemon's flag, not the pane's — a dictation started mid-preview ends
    /// the preview, and so does a capture that fails to open.
    private var previewing: Bool { context.isPreviewing }

    var body: some View {
        SettingsPage {
            hero
            statsStrip
            HistorySection(store: store)
            generalCard
            AdvancedDisclosure {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    sensitivityCard
                    storageCard
                    countingCard
                    logCard
                }
            }
        }
        .onAppear {
            refreshMicrophone()
            stats.reload(settings: store.settings)
            if openModels {
                openModels = false
                dialog = .models
            }
        }
        // Turning counting on under Advanced has to bring the strip at the top
        // to life without a pane switch in between.
        .onChange(of: store.settings.stats.enabled) { _, _ in
            stats.reload(settings: store.settings)
        }
        .onChange(of: store.settings.stats.typingWpm) { _, _ in
            stats.reload(settings: store.settings)
        }
        .onDisappear(perform: stopPreview)
        .confirmationDialog(
            "Reset usage totals?",
            isPresented: $confirmingResetStats
        ) {
            Button("Reset", role: .destructive) {
                stats.reset(settings: store.settings)
            }
        } message: {
            Text("Your lifetime word count and time saved go back to zero.")
        }
        .sheet(item: $dialog, onDismiss: refreshMicrophone) { which in
            switch which {
            case .shortcuts: ShortcutsDialog(store: store) { dialog = nil }
            case .languages: LanguagesDialog(store: store) { dialog = nil }
            case .microphone: MicrophoneDialog(store: store) { dialog = nil }
            case .models:
                ModelsDialog(store: store, catalog: catalog, context: context) { dialog = nil }
            }
        }
    }

    // MARK: - Hero

    /// No card: the headline is the page speaking, not a setting in a group,
    /// and a raised surface around it made the key read as one more row.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("Hold")
                HeroKeycap(label: store.settings.hotkey.displayLabel) {
                    dialog = .shortcuts
                }
                // "on" and the cycling word are one phrase, so they sit closer
                // than the sentence's own spacing.
                HStack(spacing: 5) {
                    Text("to dictate on")
                    RotatingWords(words: ["Web", "Messages", "Email", "Anything"])
                }
            }
            .font(.system(size: 23, weight: .medium))

            Text(heroSubline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    // MARK: - General

    /// The settings themselves, under the transcripts rather than above them:
    /// each is a decision made once, and the row already says what it was
    /// decided to be, so scrolling past them costs nothing.
    private var generalCard: some View {
        SettingsCard(header: "General") {
            SettingsDialogRow(
                label: "Model",
                value: modelSummary,
                action: "Change"
            ) { dialog = .models }

            SettingsDialogRow(
                label: "Languages",
                value: languageSummary,
                action: "Change"
            ) { dialog = .languages }

            SettingsDialogRow(
                label: "Microphone",
                value: microphone,
                action: "Change"
            ) { dialog = .microphone }

            SettingsRow(
                label: "Mute audio while dictating",
                description: "Automatically mute system audio while you're dictating."
            ) {
                Toggle("", isOn: $store.settings.audio.muteWhileDictating)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRow(
                label: "Launch at login",
                description: launchAgent.error
                    ?? "Runs in the background, in the menu bar. No dock icon."
            ) {
                Toggle("", isOn: Binding(
                    get: { launchAgent.installed },
                    set: { wanted in Task { await launchAgent.setInstalled(wanted) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(launchAgent.working)
            }
        }
    }

    /// Which model, and the one thing that follows from it — whether the audio
    /// leaves the Mac. A download in flight outranks both: it's the answer to
    /// "why isn't it dictating yet?".
    private var modelSummary: String {
        let model = store.settings.resolvedModel
        if case .downloading(let fraction, _) = catalog.state(for: model) {
            return "\(model.displayName) · downloading \(Int((fraction * 100).rounded()))%"
        }
        return model.displayName + (model.isLocal ? " · on this Mac" : " · sends audio to OpenAI")
    }

    /// The rest of what the keys do, in one quiet line under the headline.
    /// Names rather than keycap glyphs: "⌃ squawks" is a rebus, and this line
    /// is a sentence.
    private var heroSubline: String {
        var pieces: [String] = []
        let squawk = store.settings.squawk
        if squawk.enabled, squawk.isUsable(alongside: store.settings.hotkey) {
            pieces.append("hold \(squawk.hotkey.displayName) to squawk")
        }
        if store.settings.latch.enabled {
            pieces.append("double-tap to latch")
        }
        guard !pieces.isEmpty else {
            return "Release, and the words land wherever your cursor is."
        }
        let line = pieces.joined(separator: " · ")
        return line.prefix(1).capitalized + line.dropFirst() + "."
    }

    private var languageSummary: String {
        let names = LanguageSelection.displayNames(store.settings.languages)
        guard !names.isEmpty else {
            return "Auto-detects everything, types any alphabet."
        }
        return names.joined(separator: ", ")
    }

    private func refreshMicrophone() {
        microphone = MicrophoneSummary.describe(uid: store.settings.audio.inputDeviceUID)
    }

    // MARK: - Stats

    /// Nothing until there is something to count — a strip of zeros on first
    /// launch would read as a scoreboard for a game not yet played.
    @ViewBuilder
    private var statsStrip: some View {
        if store.settings.stats.enabled, let summary = stats.summary, summary.sessions > 0 {
            SettingsCard {
                SettingsCustomRow(verticalPadding: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        StatCell(
                            label: "Dictated",
                            value: summary.words.formatted(),
                            unit: "words"
                        )
                        StatCell(
                            label: "Time saved",
                            value: Stats.duration(summary.secondsSaved)
                        )
                        StatCell(
                            label: "Speaking speed",
                            value: "\(Int(summary.averageWpm.rounded()))",
                            unit: "wpm"
                        )
                        StatCell(
                            label: "Days used",
                            value: summary.daysUsed.formatted()
                        )
                    }
                }
            }
        }
    }

    // MARK: - Advanced

    /// Sensitivity is impossible to judge from a number — it depends on your
    /// mic, your room and how loudly you talk. So the card can put the real pill
    /// on screen and feed it your actual voice while you drag the slider, rather
    /// than asking you to guess and then find out mid-sentence.
    private var sensitivityCard: some View {
        SettingsCard(
            header: "Recording pill",
            footer: "Higher lowers the noise floor, so a quiet mic or a soft voice still "
                + "fills the meter on the recording pill. This only changes the picture — "
                + "it has no effect on what gets transcribed."
        ) {
            SettingsRow(label: "Meter response", description: sensitivityDescription) {
                StepperSlider(
                    value: Binding(
                        get: { overlay.sensitivity },
                        set: {
                            store.settings.overlay.sensitivity =
                                OverlaySettings.clampSensitivity($0)
                            syncPreview()
                        }
                    ),
                    range: 0.25...3,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0) }
                )
            }

            SettingsCustomRow(verticalPadding: 12) {
                HStack(spacing: 10) {
                    Button {
                        previewing ? stopPreview() : startPreview()
                    } label: {
                        Label(
                            previewing ? "Stop preview" : "Preview with your microphone",
                            systemImage: previewing ? "stop.fill" : "mic.fill"
                        )
                    }
                    .controlSize(.small)
                    .disabled(!context.isLive)

                    Text(previewHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var sensitivityDescription: String {
        switch overlay.sensitivity {
        case ..<0.7: return "Only louder speech moves the meter."
        case 1.4...: return "Picks up quiet speech, and some room noise with it."
        default: return "The default. Tuned against a MacBook mic in a normal room."
        }
    }

    private var previewHint: String {
        if !context.isLive {
            return "Start parrot to preview against live audio."
        }
        return previewing
            ? "Talk — the pill is live at the bottom of the screen."
            : "Puts the real pill on screen and feeds it your microphone."
    }

    private func startPreview() {
        context.startOverlayPreview?(overlay.sensitivity)
    }

    private func stopPreview() {
        guard previewing else { return }
        context.endOverlayPreview?()
    }

    private func syncPreview() {
        guard previewing else { return }
        context.updateOverlayPreview?(overlay.sensitivity)
    }

    /// The switches that govern the history list above. Settings you touch
    /// once, so they live down here rather than crowding the list itself.
    private var storageCard: some View {
        SettingsCard(
            header: "Transcript storage",
            footer: "Everything stays on this Mac, as JSON lines at "
                + "\(ParrotPaths.historyFile.path)."
        ) {
            SettingsRow(
                label: "Keep a history",
                description: "Every transcript, with the raw text before cleanup."
            ) {
                Toggle("", isOn: $store.settings.history.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.settings.history.enabled {
                SettingsRow(
                    label: "Keep at most",
                    description: "Older entries are pruned at startup."
                ) {
                    StepperSlider(
                        value: Binding(
                            get: { Double(store.settings.history.maxEntries) },
                            set: { store.settings.history.maxEntries = Int($0) }
                        ),
                        range: 100...20000,
                        step: 100,
                        format: { "\(Int($0).formatted())" }
                    )
                }
            }

            SettingsRow(label: "Stored file", description: nil, wideControl: true) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        ParrotPaths.historyFile.path,
                        inFileViewerRootedAtPath: ParrotPaths.dataDirectory.path
                    )
                }
            }
        }
    }

    /// The switches behind the numbers at the top of the page. Counts only —
    /// never the text — so this is a dial, not a decision, and it lives here.
    private var countingCard: some View {
        SettingsCard(
            header: "Usage counting",
            footer: "Counts only — never the text you dictated. Kept in its own "
                + "file, so clearing history doesn't reset these."
        ) {
            SettingsRow(label: "Count what I dictate", description: nil) {
                Toggle("", isOn: $store.settings.stats.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.settings.stats.enabled {
                SettingsRow(
                    label: "Compare against typing at",
                    description: "Used only to work out “time saved”. 40 wpm is "
                        + "composing-original-text speed, well below a typing test."
                ) {
                    StepperSlider(
                        value: Binding(
                            get: { store.settings.stats.typingWpm },
                            set: { store.settings.stats.typingWpm = StatsSettings.clampWpm($0) }
                        ),
                        range: 10...200,
                        step: 5,
                        format: { "\(Int($0)) wpm" }
                    )
                }

                SettingsRow(
                    label: "Stored totals",
                    description: stats.storedSummary,
                    wideControl: true
                ) {
                    Button("Reset…") { confirmingResetStats = true }
                        .disabled((stats.summary?.sessions ?? 0) == 0)
                }
            }
        }
    }

    private var logCard: some View {
        SettingsCard(header: "Diagnostics") {
            SettingsRow(
                label: "Log file",
                description: ParrotPaths.stderrLog.path,
                wideControl: true
            ) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        ParrotPaths.stderrLog.path,
                        inFileViewerRootedAtPath: ParrotPaths.logDirectory.path
                    )
                }
            }

            // Settings apply live, so this isn't the price of changing one —
            // it's here for picking up a rebuilt binary. Only offered when
            // launchd can actually bring us back; from a terminal it would just
            // quit, which isn't a restart.
            if isManagedByLaunchd {
                SettingsRow(
                    label: "Restart parrot",
                    description: "Picks up a rebuilt binary. Settings already apply live.",
                    wideControl: true
                ) {
                    // `kickstart -k` rather than terminating: launchd's KeepAlive
                    // ignores a clean exit, so quitting would stop parrot rather
                    // than restart it.
                    Button("Restart") { LaunchAgent.kickstart() }
                }
            }
        }
    }

    /// A LaunchAgent-started process is reparented to launchd (pid 1).
    private var isManagedByLaunchd: Bool { getppid() == 1 }
}

/// The hotkey drawn as the key it is, sitting inside the headline sentence.
/// Clicking it opens the bindings dialog — the cap *is* the setting, so the
/// cap is the way in.
///
/// It has to look pressable at a glance, without a card behind it to say so:
/// a raised face, a lip under it, and a hover that tints rather than just
/// outlines. The whole thing sinks onto the lip when clicked.
private struct HeroKeycap: View {
    let label: String
    let open: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: open) {
            cap
                .overlay(
                    // The glass carries the surface; this ring is the "you can
                    // click me" answer, so it stays in both worlds.
                    shape.strokeBorder(
                        hovering ? Color.accentColor : SettingsPalette.keycapBorder,
                        lineWidth: hovering ? 1.5 : 0.5
                    )
                )
                .contentShape(shape)
        }
        .buttonStyle(KeycapPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Change key bindings")
        .accessibilityLabel("Dictation key: \(label). Change key bindings")
    }

    /// Liquid Glass where the OS has it, a raised keycap everywhere else — the
    /// same rule the `GlassTabs` puck follows.
    @ViewBuilder
    private var cap: some View {
        let text = Text(label)
            .font(.system(size: 19, weight: .medium, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        if #available(macOS 26.0, *) {
            text
                .glassEffect(.regular.interactive(), in: shape)
                .background(hoverTint)
        } else {
            text
                .background(shape.fill(SettingsPalette.keycapFace))
                .background(hoverTint)
        }
    }

    /// A wash of the accent under the face, so hovering warms the button up
    /// instead of only drawing a line around it.
    private var hoverTint: some View {
        shape.fill(Color.accentColor.opacity(hovering ? 0.14 : 0))
    }
}

/// Down onto the lip, like a key. `.plain` alone gives no press feedback at
/// all, which makes the cap read as a label rather than the way in.
private struct KeycapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .offset(y: pressed ? 1.5 : 0)
            .shadow(
                color: .black.opacity(pressed ? 0.14 : 0.38),
                radius: pressed ? 1.5 : 4,
                y: pressed ? 0.5 : 2
            )
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// The tail of the headline, cycling through where dictation lands. One word
/// at a time rather than a list: the point is that it works everywhere, and a
/// comma-separated four makes that a claim to read instead of watch.
private struct RotatingWords: View {
    let words: [String]
    var interval: Duration = .milliseconds(2000)

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The clip belongs to the container, not the word: a `.clipped()` on
        // the word itself travels with it and clips nothing.
        ZStack(alignment: .leading) {
            Text(words[index])
                .italic()
                .id(index)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
        }
        .clipped()
        .task {
            // Tied to the view's lifetime, so it stops with the pane and isn't
            // restarted by every redraw the way a Timer publisher is.
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    index = (index + 1) % words.count
                }
            }
        }
        .accessibilityLabel(words.joined(separator: ", "))
    }
}

/// One number in the strip: what it is, then the number at full weight.
private struct StatCell: View {
    let label: String
    let value: String
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reads the stats file for the strip. Kept out of the view so opening the
/// window doesn't re-read it on every redraw.
@MainActor
private final class HomeStats: ObservableObject {
    @Published private(set) var summary: StatsSummary?

    func reload(settings: Settings) {
        guard settings.stats.enabled else {
            summary = nil
            return
        }
        summary = StatsStore(settings: settings.stats)
            .summary(typingWpm: settings.stats.typingWpm)
    }

    var storedSummary: String {
        guard let summary, summary.sessions > 0 else { return "Nothing counted yet" }
        let days = summary.daysUsed
        return "Across \(days) \(days == 1 ? "day" : "days")"
    }

    func reset(settings: Settings) {
        try? StatsStore(settings: settings.stats).reset()
        reload(settings: settings)
    }
}

/// A slider with its value spelled out beside it. Numeric fields for these
/// would invite values that make no sense — a 5 ms tap threshold, a 4-hour
/// safety stop — and the exact number is never what the user is choosing.
struct StepperSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            // Quantised in the binding rather than by `Slider(step:)`, which
            // draws a tick mark per step on macOS — 118 of them for the safety
            // stop, which reads as a hatched bar rather than a slider.
            Slider(value: quantised, in: range)
            Text(format(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private var quantised: Binding<Double> {
        Binding(
            get: { value },
            set: { raw in
                let snapped = (raw / step).rounded() * step
                value = min(range.upperBound, max(range.lowerBound, snapped))
            }
        )
    }
}

/// Reads and writes the launchd agent, and keeps the toggle honest about what
/// actually happened — a failed `bootstrap` has to show up as the switch
/// coming back rather than as silence.
@MainActor
private final class LaunchAgentState: ObservableObject {
    @Published private(set) var installed = LaunchAgent.isInstalled
    @Published private(set) var error: String?

    /// Off the main thread, because flipping the switch is two `launchctl`
    /// round-trips and a plist write — done inline it beachballs the window
    /// until launchd answers. The toggle is left disabled meanwhile so it can't
    /// be flipped again mid-flight.
    @Published private(set) var working = false

    func setInstalled(_ wanted: Bool) async {
        guard !working else { return }
        working = true
        error = nil
        let failure = await Task.detached { () -> String? in
            do {
                if wanted {
                    let binary = try LaunchAgent.resolveBinary(override: nil)
                    try LaunchAgent.install(binary: binary)
                    LaunchAgent.bootout()
                    let result = LaunchAgent.bootstrap()
                    guard result.ok else {
                        try? LaunchAgent.uninstall()
                        throw LaunchFailure.launchctl(result.stderr)
                    }
                } else {
                    try LaunchAgent.uninstall()
                }
            } catch {
                return "\(error)"
            }
            return nil
        }.value
        error = failure
        installed = LaunchAgent.isInstalled
        working = false
    }

    enum LaunchFailure: Error, CustomStringConvertible {
        case launchctl(String)

        var description: String {
            switch self {
            case .launchctl(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "launchctl refused to load the agent\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }
}
