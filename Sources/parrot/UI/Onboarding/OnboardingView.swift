import AVFoundation
import AppKit
import SwiftUI

/// The five things that have to be true before parrot can do anything, in the
/// order they depend on each other.
///
/// Deliberately short. Everything else parrot can do — cleanup, squawk, the
/// dictionary, a second key — is something to discover later in Settings, and
/// putting any of it here would make the one path that matters longer.
enum OnboardingStep: Int, CaseIterable, Hashable {
    case welcome
    case microphone
    case accessibility
    case key
    case ready

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// First run, as a sequence rather than a settings window.
///
/// The Permissions pane says all of the same things, but it says them all at
/// once, next to ten other tabs, to someone who has not yet seen parrot do
/// anything. This asks for one thing at a time, in an order where each step is
/// the reason the next one matters, and ends with the user's own voice landing
/// in a text field.
struct OnboardingView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext
    let finish: () -> Void

    /// The window is fixed at exactly this, and the view says so rather than
    /// leaving it to `NSHostingView` to work out: a `maxHeight: .infinity`
    /// anywhere inside makes the fitting size unbounded, and a window with no
    /// resize control takes that literally.
    ///
    /// Sized to the tallest step rather than to a round number — the key step
    /// carrying its Fn warning. Anything taller is dead space under the card on
    /// the other four, which reads as a window that failed to fill itself.
    static let windowSize = CGSize(width: 700, height: 492)

    /// The band the steps are drawn in, top-aligned.
    ///
    /// Fixed, and every step's header is fixed inside it, so the title and the
    /// card under it land on the same two lines on all five screens. Centring
    /// each step in the space it happened to need instead moved the title by
    /// over a hundred points between steps — nobody would name it, but the
    /// whole thing read as unsettled.
    private static let contentHeight: CGFloat = 344

    @StateObject private var checks = OnboardingChecks()
    @State private var step: OnboardingStep = .welcome
    /// Which way the last move went, so the two panes slide past each other
    /// rather than both entering from the same side.
    @State private var advancing = true
    /// True for the length of the send-off. The burst itself is a screen-wide
    /// panel that outlives this window, so all this view keeps is the fact that
    /// it is on its way out.
    @State private var celebrating = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepBar(step: step)
                .padding(.horizontal, 34)
                // Clears the traffic lights — the title bar is transparent and
                // the content runs underneath it.
                .padding(.top, 30)

            content
                .id(step)
                .transition(stepTransition)
                .frame(height: Self.contentHeight, alignment: .top)
                .padding(.top, 42)
                .padding(.horizontal, 46)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(SettingsPalette.pageBackground)
        .onAppear {
            checks.watchFnKey = shouldWatchFnKey
            checks.start()
        }
        .onDisappear { checks.stop() }
        .onChange(of: store.settings.hotkey) { _, _ in
            checks.watchFnKey = shouldWatchFnKey
        }
        .onChange(of: step) { _, _ in
            checks.watchFnKey = shouldWatchFnKey
        }
    }

    /// The Fn check spawns `defaults` on every tick, and the key step is the
    /// only thing that reads the answer — so it runs while that step is up and
    /// not for the rest of the window's life.
    private var shouldWatchFnKey: Bool {
        step == .key && store.settings.hotkey == .fn
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .microphone:
            MicrophoneStep(checks: checks)
        case .accessibility:
            AccessibilityStep(checks: checks)
        case .key:
            KeyStep(store: store, checks: checks)
        case .ready:
            ReadyStep(store: store, catalog: catalog, context: context)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let previous = step.previous {
                Button("Back") { go(to: previous) }
                    .controlSize(.large)
            }

            Spacer(minLength: 0)

            // Never a dead end: a grant can fail for reasons parrot can't see —
            // a managed Mac, a permission the user wants to think about — and
            // trapping someone on step three of five over it would be worse
            // than letting them through to a menu bar icon that says what's
            // still missing.
            if !canAdvance, let skip = skipLabel {
                Button(skip) { advance() }
                    .buttonStyle(.link)
                    .controlSize(.large)
            }

            Button(primaryLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!canAdvance)
        }
        // Once the send-off is playing the window is on its way out. Leaving
        // Back live would let someone walk into step four of a setup that is
        // about to close itself.
        .disabled(celebrating)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .ready: return "Done"
        default: return "Continue"
        }
    }

    private var skipLabel: String? {
        switch step {
        case .microphone, .accessibility: return "Skip for now"
        default: return nil
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .microphone: return checks.microphoneGranted
        case .accessibility: return checks.accessibility
        default: return true
        }
    }

    private func advance() {
        guard let next = step.next else {
            celebrateAndFinish()
            return
        }
        go(to: next)
    }

    /// Setup is finished exactly once per Mac, which makes it the one place in
    /// parrot where delight costs nothing. Everything else here is a daemon that
    /// stays out of the way.
    ///
    /// The window goes while the paper is still in the air. It can: the burst
    /// is its own screen-wide panel, so closing on schedule doesn't cut the
    /// celebration short — the confetti carries on over whatever was behind.
    private func celebrateAndFinish() {
        guard !celebrating else { return }
        guard !reduceMotion else {
            finish()
            return
        }
        celebrating = true
        ConfettiOverlay.fire(on: NSApp.keyWindow?.screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { finish() }
    }

    private func go(to next: OnboardingStep) {
        advancing = next.rawValue > step.rawValue
        // Barely any overshoot: this is a page turn, not a toy. Fast enough to
        // feel like the button answered, slow enough to show which way the
        // sequence runs.
        withAnimation(
            reduceMotion
                ? .easeOut(duration: 0.16)
                : .spring(response: 0.28, dampingFraction: 0.92)
        ) {
            step = next
        }
    }

    /// The step slides in from the side it is coming from. Reduced motion keeps
    /// the crossfade — it still says a screen changed — and drops the travel.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: advancing ? 26 : -26).combined(with: .opacity),
            removal: .offset(x: advancing ? -26 : 26).combined(with: .opacity)
        )
    }
}

// MARK: - Chrome

/// One segment per step, filled up to where you are. A continuous bar would say
/// "some fraction done"; five segments say how many questions are left, which
/// is the thing someone at the start of a setup actually wants to know.
private struct StepBar: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStep.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue
                        ? Color.accentColor
                        : Color.secondary.opacity(0.18))
                    .frame(height: 3)
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

/// Title and one paragraph, in a slot of fixed height.
///
/// Fixed so that a two-line subtitle and a three-line one both leave the card
/// below them on the same line. The alternative is a card that shifts by a
/// line's height every time the step changes.
private struct StepHeader: View {
    let title: String
    let subtitle: String

    private static let height: CGFloat = 86

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 23, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(height: Self.height, alignment: .top)
    }
}

/// The one raised surface a step is allowed. Matches the settings window's
/// cards so the two don't read as different apps.
private struct StepCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(SettingsPalette.cardBorder, lineWidth: 0.5)
            )
            .frame(maxWidth: 460)
    }
}

/// A settled step: a green tick and the past tense, so a step you come back to
/// reads as finished rather than as one more thing to do.
private struct GrantedNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
    }
}

// MARK: - Welcome

/// The one step that is a title card rather than a question, so it is centred in
/// the band instead of pinned to the top of it.
private struct WelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let facts: [(symbol: String, text: String)] = [
        ("cpu", "Runs on this Mac"),
        ("keyboard", "Types into any app"),
        ("menubar.arrow.up.rectangle", "Lives in the menu bar"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            if let glyph = ParrotGlyph.image(size: 52) {
                Image(nsImage: glyph)
                    .renderingMode(.template)
                    .foregroundStyle(Color.accentColor)
                    // From 0.94, never from nothing — a mark that pops out of
                    // zero reads as an effect rather than as the app arriving.
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.32), value: appeared)
            }

            StepHeader(
                title: "parrot",
                subtitle: "Hold a key and talk. What you said is typed wherever your "
                    + "cursor already is. Three things to set up, about a minute."
            )

            HStack(spacing: 26) {
                ForEach(Array(Self.facts.enumerated()), id: \.offset) { index, fact in
                    Fact(symbol: fact.symbol, text: fact.text)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 6)
                        // Staggered so the row assembles left to right instead
                        // of landing as one block. Short delays — long ones read
                        // as the window being slow to draw.
                        .animation(
                            .easeOut(duration: 0.26).delay(0.16 + 0.06 * Double(index)),
                            value: appeared
                        )
                }
            }
            .padding(.top, 4)
        }
        .frame(maxHeight: .infinity)
        .onAppear { appeared = true }
    }

    private struct Fact: View {
        let symbol: String
        let text: String

        var body: some View {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Microphone

private struct MicrophoneStep: View {
    @ObservedObject var checks: OnboardingChecks
    @StateObject private var tester = MicTester()

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                title: "Let parrot hear you",
                subtitle: "The microphone opens while you hold the key and closes when you "
                    + "let go. Nothing is recorded in between."
            )

            StepCard {
                if checks.microphoneGranted {
                    VStack(spacing: 14) {
                        MicMeter(model: tester.meter)
                        Text(tester.heard ? "That's it — your microphone works." : "Say something.")
                            .font(.system(size: 12))
                            .foregroundStyle(tester.heard ? .primary : .secondary)
                            .animation(.easeOut(duration: 0.2), value: tester.heard)
                    }
                } else if checks.microphoneDenied {
                    VStack(spacing: 12) {
                        Text("macOS won't ask a second time once it's been denied, so this "
                            + "one has to be switched back on by hand.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Microphone settings") {
                            PermissionActions.openMicrophoneSettings()
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Button("Allow microphone") {
                            Task {
                                await PermissionActions.requestMicrophone()
                                checks.refresh()
                            }
                        }
                        .controlSize(.large)
                        Text("macOS will ask.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // The card's contents swap the moment the system prompt is
            // answered — with the user still looking straight at it.
            .animation(.easeOut(duration: 0.22), value: checks.microphone)
        }
        // Keyed on the grant, not just onAppear: the meter has to start the
        // moment the system prompt is answered, which happens with this step
        // already on screen.
        .onChange(of: checks.microphoneGranted) { _, granted in
            if granted { tester.start() } else { tester.stop() }
        }
        .onAppear { if checks.microphoneGranted { tester.start() } }
        .onDisappear { tester.stop() }
    }
}

// MARK: - Accessibility

private struct AccessibilityStep: View {
    @ObservedObject var checks: OnboardingChecks

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                title: "Let parrot type for you",
                subtitle: "One grant covers both halves of dictation. It's the only one "
                    + "parrot can't work without."
            )

            StepCard {
                if checks.accessibility {
                    GrantedNotice(text: "Granted — parrot can type.")
                } else {
                    VStack(spacing: 16) {
                        // Named rather than asserted. Accessibility is the grant
                        // people hesitate over, and "it needs Accessibility" is
                        // not a reason — this is the two things it buys.
                        VStack(alignment: .leading, spacing: 10) {
                            Unlock(symbol: "keyboard", text: "Notice the key you're holding")
                            Unlock(symbol: "text.cursor", text: "Put the words at your cursor")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        VStack(spacing: 10) {
                            Button("Open Accessibility settings") {
                                PermissionActions.promptAccessibility()
                            }
                            .controlSize(.large)
                            Text("Find parrot in the list and switch it on. This window "
                                + "notices on its own — there's nothing to come back and press.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.22), value: checks.accessibility)
        }
    }

    private struct Unlock: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Key

private struct KeyStep: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var checks: OnboardingChecks

    @StateObject private var probe = KeyProbe()

    private var key: Hotkey { store.settings.hotkey }
    private var isDown: Bool { probe.isDown(key) }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                title: "Pick your key",
                subtitle: "Hold it and talk, let go and parrot types. Double-tap it instead "
                    + "to keep recording hands-free."
            )

            StepCard {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(Hotkey.presets, id: \.self) { preset in
                            HotkeyOption(
                                hotkey: preset,
                                selected: key == preset,
                                // Only the chosen one lights. Lighting whichever
                                // key happened to be held would say every one of
                                // them is live, which is the opposite of the
                                // thing this step is asking.
                                pressed: key == preset && isDown
                            ) {
                                store.settings.hotkey = preset
                            }
                        }
                    }

                    status
                }
            }

            if let warning = fnWarning {
                StepCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(warning)
                                .font(.system(size: 12, weight: .medium))
                            Text("Set “Press 🌐 key to” to “Do Nothing” so Fn stays a plain "
                                + "modifier — otherwise macOS answers it before parrot sees it.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Open") { PermissionActions.openKeyboardSettings() }
                            .controlSize(.small)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: fnWarning)
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    /// One line, in a slot that doesn't move.
    ///
    /// The first line answers the question the user is about to ask by pressing
    /// the key — did it see that? — and the second stays put so the caption
    /// under the caps doesn't reflow every time a key goes down.
    private var status: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if probe.hasAnswered(key) {
                    Image(systemName: isDown ? "circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isDown ? Color.accentColor : .green)
                        .transition(.opacity)
                }
                Text(statusText)
                    .font(.system(size: 11, weight: probe.hasAnswered(key) ? .medium : .regular))
                    .foregroundStyle(probe.hasAnswered(key) ? .primary : .secondary)
            }
            .frame(height: 14)

            Text("Escape throws a recording away.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.16), value: isDown)
        .animation(.easeOut(duration: 0.2), value: probe.hasAnswered(key))
    }

    private var statusText: String {
        let name = key.displayName
        if isDown { return "parrot sees \(name)." }
        if probe.hasAnswered(key) { return "\(name) works — hold it and talk." }
        return "Press \(name) to check parrot sees it."
    }

    /// Only when Fn is actually the chosen key — the mapping is irrelevant to
    /// anyone holding Option, and warning them about it would be noise.
    private var fnWarning: String? {
        guard store.settings.hotkey == .fn else { return nil }
        switch checks.fnKey {
        case .ok: return nil
        case .warn(let message), .fail(let message): return "Fn is \(message)."
        }
    }
}

// MARK: - Ready

private struct ReadyStep: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext

    @State private var scratch = ""
    @State private var daemonRunning = false
    @FocusState private var scratchFocused: Bool

    private var model: TranscriptionModel { store.settings.resolvedModel }
    private var state: ModelState { catalog.state(for: model) }

    private var isReady: Bool {
        if case .ready = context.engineStatus { return true }
        return false
    }

    /// Whether anything is actually listening for the hotkey.
    ///
    /// `parrot setup` opens this window in a process of its own, so its
    /// `engineStatus` says "not running" however healthy the real daemon is.
    /// Asking launchd is the only way to tell that case apart from a Mac where
    /// parrot genuinely hasn't been started.
    private var canTry: Bool {
        if isReady { return true }
        if case .notRunning = context.engineStatus { return daemonRunning }
        return false
    }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: title, subtitle: subtitle)

            StepCard {
                VStack(spacing: 12) {
                    modelStatus

                    if canTry {
                        TextField("", text: $scratch, prompt: Text(prompt), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(2...4)
                            .focused($scratchFocused)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(SettingsPalette.pageBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(SettingsPalette.cardBorder, lineWidth: 0.5)
                            )
                    }
                }
            }

            Text("parrot is in the menu bar from here on — the bird icon has your recent "
                + "transcripts, and Settings is where cleanup, a second key and your own "
                + "vocabulary live.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .onAppear {
            catalog.refresh()
            // launchctl is a subprocess spawn, and this fires as the step is
            // sliding in. Off the main thread so it doesn't eat the animation.
            Task.detached {
                let running = LaunchAgent.state().isRunning
                await MainActor.run { daemonRunning = running }
            }
            // Focused so the try-it field is where the keystrokes land. The
            // window is key while the user holds the hotkey, so this is the only
            // thing standing between them and seeing it work.
            scratchFocused = true
        }
        .onChange(of: canTry) { _, ready in
            if ready { scratchFocused = true }
        }
    }

    private var title: String {
        canTry ? "Try it" : "Almost there"
    }

    private var subtitle: String {
        if canTry {
            return "Hold \(store.settings.hotkey.displayName), say something, and let go."
        }
        if case .notRunning = context.engineStatus {
            return "Nothing is listening yet. Start parrot from the menu bar, or run "
                + "parrot start in a terminal to have it come back at every login."
        }
        // A model that failed to load is not a model on its way in. Saying it
        // is leaves someone waiting on a download that isn't happening.
        if case .failed = context.engineStatus {
            return "The speech model didn't load. The reason is below — "
                + "downloading it again is usually what fixes it."
        }
        return "The speech model is being fetched. It only happens once, and it "
            + "stays on this Mac."
    }

    private var prompt: String {
        "Hold \(store.settings.hotkey.displayName) and say something here"
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch state {
        case .downloading(let fraction, let phase):
            VStack(spacing: 7) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.25), value: fraction)
                Text("\(phase) \(model.displayName) · \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            VStack(spacing: 10) {
                Text("\(model.displayName) hasn't been downloaded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Download · \(model.sizeMB) MB") { catalog.download(model) }
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { catalog.download(model) }
            }
        case .installed, .remote:
            if isReady {
                GrantedNotice(text: "\(model.displayName) is loaded.")
            } else if canTry {
                GrantedNotice(text: "\(model.displayName) is ready.")
            } else if case .notRunning = context.engineStatus {
                // No daemon behind this window — `parrot setup` run on its own.
                // A spinner here would be waiting for something that is never
                // going to happen.
                Text("\(model.displayName) is downloaded and ready to load.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if case .failed(let why) = context.engineStatus {
                // The file is on disk but the engine wouldn't take it. The
                // catalog still says .installed, so this is the only place the
                // failure surfaces — and a spinner over it would never stop.
                VStack(spacing: 10) {
                    Text(why)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Download again") { catalog.download(model) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(engineLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var engineLabel: String {
        switch context.engineStatus {
        case .loading(let what): return what
        case .failed(let why): return why
        case .notRunning: return "Not running"
        case .ready(let id): return id
        }
    }
}
