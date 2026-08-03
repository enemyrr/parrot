import AppKit
import SwiftUI

/// The model behind squawk, what it's told about you, and how much of the
/// screen it gets to see.
struct SquawkPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var models = ModelListState()
    @StateObject private var inspector = ContextInspector()

    private var squawk: SquawkSettings { store.settings.squawk }

    var body: some View {
        SettingsPage(
            title: "Squawk",
            subtitle: "Say what you want done. It reads the app you're in and writes the answer."
        ) {
            enableCard

            if squawk.enabled {
                providerSection
                modelCard
                aboutSection
                voiceCard
                promptSection
                contextCard
                checkCard
                privacyCard
            }
        }
        .onAppear { models.load(squawk.provider) }
        .onChange(of: squawk.provider) { _, new in models.load(new) }
    }

    /// Always on the page, never only in the off state. A switch that vanishes
    /// once it is on leaves the feature with no way out of the room it let you
    /// into — which is what the Integrations pane did until this shape was
    /// shared with it.
    private var enableCard: some View {
        SettingsCard(
            footer: squawk.enabled
                ? nil
                : "Nothing here runs until it's on: no second key, no reading the screen, "
                    + "no requests."
        ) {
            SettingsRow(
                label: squawk.enabled ? "Squawk is on" : "Squawk is off",
                description: squawk.enabled
                    ? "Hold \(squawk.hotkey.displayName) and say what you want done."
                    : "Flip this on, then pick a model below."
            ) {
                Toggle("", isOn: $store.settings.squawk.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Provider

    /// Unboxed, like every other row of pickable cards in the window: each chip
    /// already draws its own edge, and a card around them is a border whose only
    /// job is to fence off something that was never ambiguous.
    private var providerSection: some View {
        SettingsSection(header: "Provider", footer: providerFooter) {
            HStack(spacing: 10) {
                ForEach(LLMProvider.allCases) { provider in
                    ProviderOption(
                        provider: provider,
                        selected: squawk.provider == provider,
                        available: Self.isAvailable(provider)
                    ) {
                        store.settings.squawk.provider = provider
                        // A model id from one vendor is meaningless to
                        // another, and sending it produces a 404 mid-squawk.
                        store.settings.squawk.model = ""
                    }
                }
            }
        }
    }

    // MARK: - Model

    private var modelCard: some View {
        SettingsCard(header: "Model") {
            if squawk.provider != .apple {
                SettingsRow(
                    label: "Model",
                    description: "Which model writes the answer.",
                    wideControl: true
                ) {
                    ModelPicker(
                        provider: squawk.provider,
                        model: $store.settings.squawk.model,
                        hasKey: Self.hasKey(squawk.provider),
                        list: models
                    )
                }
            }

            if squawk.provider == .openai {
                SettingsRow(
                    label: "Reasoning",
                    description: "Higher thinks longer before writing. Costs latency."
                ) {
                    Picker("", selection: $store.settings.squawk.reasoningEffort) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            SettingsRow(
                label: "Give up after",
                description: "A model that never answers must not leave you waiting."
            ) {
                StepperSlider(
                    value: $store.settings.squawk.timeoutS,
                    range: 5...60,
                    step: 5,
                    format: { "\(Int($0))s" }
                )
            }
        }
    }

    /// Whether a provider could actually run a squawk right now — the on-device
    /// one needs the OS and Apple Intelligence, the API ones need a key.
    static func isAvailable(_ provider: LLMProvider) -> Bool {
        provider == .apple ? AppleCleanupAvailability.isAvailable : hasKey(provider)
    }

    static func hasKey(_ provider: LLMProvider) -> Bool {
        guard let account = provider.keychainAccount else { return true }
        return Keychain.apiKey(for: account) != nil
    }

    private var providerFooter: String? {
        if squawk.provider == .apple {
            if let reason = AppleCleanupAvailability.unavailableReason {
                return "⚠ \(reason)."
            }
            return "On-device: what's on your screen never leaves this Mac. It writes less "
                + "well than the API models on anything long."
        }
        return "This one sees what's on your screen. Everything in the Privacy card below "
            + "applies to it."
    }

    // MARK: - Style

    /// Who you are, plus a way through to how each app is written for.
    ///
    /// "About you" is edited here rather than in Style because it is the one
    /// thing on either screen that squawk uses and dictation cannot: dictation
    /// repairs a transcript, and repairing it never requires knowing who said
    /// it. In Style it had to sit under a tab bar that scoped everything else to
    /// one category, so the page said "this category" and then quietly stopped
    /// meaning it.
    ///
    /// Tone and length stay in Style, and this shows what they currently are —
    /// a squawk is written by those settings as much as by anything on this
    /// screen, and finding that out by surprise is how a feature earns a
    /// reputation for ignoring you.
    private var aboutSection: some View {
        SettingsSection(
            header: "About you",
            footer: "Goes into every squawk, in every app. Who you are, what you do, what "
                + "languages you write in. This one is squawk's alone."
        ) {
            CommittedText(text: $store.settings.style.about) { draft in
                PromptEditor(
                    text: draft,
                    placeholder: "I'm Andreas, I run a staffing company in Sweden. I "
                        + "write short and direct, no corporate padding. I sign off "
                        + "with just my first name. I write Swedish with Swedish "
                        + "colleagues and English with everyone else.",
                    minHeight: 90
                )
            }
        }
    }

    private var voiceCard: some View {
        SettingsCard(
            header: "Voice",
            footer: "Tone and length are shared with dictation, so the two write as the same "
                + "person."
        ) {
            SettingsDialogRow(
                label: "Tone and length",
                value: summary,
                action: "Open Style"
            ) {
                SettingsWindowController.shared.show(pane: .style)
            }
        }
    }

    /// No "nothing about you yet" any more — the editor for it is the row above,
    /// so the reminder would be pointing at itself.
    private var summary: String {
        let style = store.settings.style
        let count = style.categories.count
        let categories = count == 1 ? "1 category" : "\(count) categories"
        return "\(categories) · \(style.fallback.tone.displayName) by default"
    }

    // MARK: - Prompt

    private var promptSection: some View {
        SettingsSection(
            header: "Base prompt",
            footer: "The rules of the mode itself — what \"rewrite this\" means, what "
                + "\"answer this\" means, and that only the text comes back. Leave it empty "
                + "for the built-in one."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                CommittedText(text: $store.settings.squawk.prompt) { draft in
                    PromptEditor(
                        text: draft,
                        placeholder: SquawkPrompt.base,
                        minHeight: 140
                    )
                }
                HStack(spacing: 8) {
                    Button("Load the built-in prompt") {
                        store.settings.squawk.prompt = SquawkPrompt.base
                    }
                    .controlSize(.small)
                    .disabled(!squawk.prompt.isEmpty)

                    Button("Reset to default") {
                        store.settings.squawk.prompt = ""
                    }
                    .controlSize(.small)
                    .disabled(squawk.prompt.isEmpty)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Context

    private var contextCard: some View {
        SettingsCard(
            header: "What it reads",
            footer: "Your selection and the field you're in are always read. The rest of the "
                + "window is what makes \"answer this email\" work without selecting it first."
        ) {
            SettingsRow(
                label: "Read the whole window",
                description: "Off means only what you've selected and the field you're typing in."
            ) {
                Toggle("", isOn: $store.settings.squawk.context.readWindow)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if squawk.context.readWindow {
                SettingsRow(
                    label: "How much",
                    description: "Roughly a screenful is 2000. More costs latency and tokens."
                ) {
                    StepperSlider(
                        value: Binding(
                            get: { Double(squawk.context.maxCharacters) },
                            set: { store.settings.squawk.context.maxCharacters = Int($0) }
                        ),
                        range: 1000...20000,
                        step: 1000,
                        format: { "\(Int($0) / 1000)k chars" }
                    )
                }
            }

            SettingsRow(
                label: "Read browsers and Electron apps",
                description: "Chrome, Slack, VS Code and Discord expose nothing without this."
            ) {
                Toggle("", isOn: $store.settings.squawk.context.enhanceChromium)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

        }
    }

    // MARK: - Check

    /// The same shape as the Integrations pane's check, because it is the same
    /// errand: switch away, let it read, see exactly what it saw.
    private var checkCard: some View {
        SettingsCard(
            header: "Check",
            footer: "Switch to the app you want to test and leave it in front. parrot reads "
                + "it \(Int(ContextInspector.delay)) seconds later and shows what it found."
        ) {
            SettingsCustomRow(verticalPadding: 10) {
                HStack(spacing: 10) {
                    Button(inspector.isRunning ? "Reading…" : "Show me what you'd send") {
                        inspector.run(settings: squawk, style: store.settings.style)
                    }
                    .controlSize(.small)
                    .disabled(inspector.isRunning)

                    if inspector.isRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }

                    Spacer()
                }
            }

            if let report = inspector.report {
                SettingsCustomRow(verticalPadding: 10) {
                    ProbeReport(text: report)
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        SettingsCard(
            header: "Never read",
            footer: "The locked ones hold whatever the settings say — a password manager's "
                + "window is a list of passwords. Every password manager parrot knows is "
                + "covered, installed or not; only the ones on this Mac are shown. Add your "
                + "own with the picker, or by bundle id for an app that isn't on this Mac."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                AppChipList(
                    bundleIDs: $store.settings.squawk.excludedBundleIDs,
                    locked: builtInExclusions,
                    lockedHelp: "Never read, whatever the settings say",
                    addLabel: "Exclude apps…",
                    pickerMessage: "Choose the apps squawk should never read."
                )
            }
        }
    }

    /// The always-excluded apps that are actually on this Mac, resolved to icons
    /// and names. Cheap on redraw — `AppCatalog` caches, so this is a handful of
    /// dictionary hits.
    ///
    /// The full list is eight entries of password managers nobody has all of, and
    /// a row of greyed-out apps you don't own reads as a list of things parrot
    /// failed to find rather than a list of things it protects. The exclusions
    /// still apply to every one of them — this only decides what's worth showing.
    private var builtInExclusions: [AppIdentity] {
        ScreenReader.alwaysExcluded
            .map { AppCatalog.identity(named: $0.name, anyOf: $0.bundleIDs) }
            .filter(\.isInstalled)
    }
}

/// Runs a real capture against whatever the user switches to, and shows exactly
/// what would be sent.
///
/// The feature reads your windows. It has to be able to show you what it read,
/// or "why did it write that" has no answer and the whole thing has to be taken
/// on faith.
@MainActor
private final class ContextInspector: ObservableObject {
    static let delay: TimeInterval = 4

    @Published var report: String?
    @Published var isRunning = false

    func run(settings: SquawkSettings, style: StyleSettings) {
        guard !isRunning else { return }
        isRunning = true
        report = nil

        let limits = settings.context.limits
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.delay * 1_000_000_000))
            let target = AppTarget.frontmost()
            guard let target else {
                self.report = "No app in front to read."
                self.isRunning = false
                return
            }
            let excluded = settings.isExcluded(bundleID: target.bundleID)
            let context = await Task.detached(priority: .userInitiated) { () -> ScreenContext in
                excluded
                    ? .skipped(.excludedApp, app: target.name, bundleID: target.bundleID)
                    : ScreenReader.capture(target, limits: limits)
            }.value

            let category = style.category(for: context.bundleID)
            self.report = """
                \(ContextCommand.report(context, full: true))

                ── style
                \(category.name) · \(category.tone.displayName) · \(category.length.displayName)
                """
            self.isRunning = false
        }
    }
}
