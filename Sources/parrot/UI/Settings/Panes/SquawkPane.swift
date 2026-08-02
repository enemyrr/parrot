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
            if !squawk.enabled {
                offCard
            } else {
                modelCard
                aboutCard
                promptCard
                profilesCard
                contextCard
                privacyCard
            }
        }
        .onAppear { models.load(squawk.provider) }
        .onChange(of: squawk.provider) { _, new in models.load(new) }
    }

    private var offCard: some View {
        SettingsCard(footer: "Nothing here runs until it's on: no second key, no reading "
            + "the screen, no requests.") {
            SettingsRow(
                label: "Squawk is off",
                description: "Turn it on in the Keys tab, then come back to pick a model."
            ) {
                Toggle("", isOn: $store.settings.squawk.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Model

    private var modelCard: some View {
        SettingsCard(header: "Model", footer: providerFooter) {
            SettingsCustomRow(verticalPadding: 12) {
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

    // MARK: - About

    private var aboutCard: some View {
        SettingsCard(
            header: "About you",
            footer: "Goes into every squawk, in every app. Who you are, how you sign off, "
                + "how you write."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                PromptEditor(
                    text: $store.settings.squawk.about,
                    placeholder: "I'm Andreas, I run a staffing company in Sweden. I write "
                        + "short and direct, no corporate padding. I sign off with just my "
                        + "first name. I write Swedish with Swedish colleagues and English "
                        + "with everyone else.",
                    minHeight: 90
                )
            }
        }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        SettingsCard(
            header: "Base prompt",
            footer: "The rules of the mode itself — what \"rewrite this\" means, what "
                + "\"answer this\" means, and that only the text comes back. Leave it empty "
                + "for the built-in one."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    PromptEditor(
                        text: $store.settings.squawk.prompt,
                        placeholder: SquawkPrompt.base,
                        minHeight: 140
                    )
                    HStack {
                        Button("Start from the built-in") {
                            store.settings.squawk.prompt = SquawkPrompt.base
                        }
                        .disabled(!squawk.prompt.isEmpty)
                        Button("Reset to default") {
                            store.settings.squawk.prompt = ""
                        }
                        .disabled(squawk.prompt.isEmpty)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        SettingsCard(
            header: "Per-app instructions",
            footer: "First match wins. An email and a chat message want different answers "
                + "to the same instruction, and nothing else can tell them apart."
        ) {
            ForEach($store.settings.squawk.profiles) { $profile in
                ProfileRow(profile: $profile) {
                    store.settings.squawk.profiles.removeAll { $0.id == profile.id }
                }
            }

            SettingsCustomRow(verticalPadding: 10) {
                HStack {
                    Button {
                        store.settings.squawk.profiles.append(
                            AppProfile(name: "New app", bundleIDs: [], instructions: "")
                        )
                    } label: {
                        Label("Add an app", systemImage: "plus")
                    }
                    Spacer()
                    Button("Restore the defaults") {
                        store.settings.squawk.profiles = AppProfile.starters
                    }
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

            SettingsCustomRow(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            inspector.run(settings: squawk)
                        } label: {
                            Label(
                                inspector.isRunning
                                    ? "Reading…"
                                    : "Show me what you'd send",
                                systemImage: "eye"
                            )
                        }
                        .disabled(inspector.isRunning)

                        Text("Switch to another app first — it reads whatever is in front "
                            + "\(Int(ContextInspector.delay))s after you click.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }

                    if let report = inspector.report {
                        ScrollView {
                            Text(report)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 220)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(SettingsPalette.keycapFill)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        SettingsCard(
            header: "Never read",
            footer: "Password managers and the login window are excluded no matter what — "
                + "that list isn't editable. Add anything else here, by bundle id."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                TokenListEditor(
                    tokens: $store.settings.squawk.excludedBundleIDs,
                    placeholder: "Bundle id — com.example.App",
                    normalize: { $0.trimmingCharacters(in: .whitespaces) },
                    validate: { $0.contains(".") }
                )
            }
        }
    }
}

/// One app profile: what it's called, which apps it claims, what to tell the
/// model when you're in one of them.
private struct ProfileRow: View {
    @Binding var profile: AppProfile
    let delete: () -> Void

    var body: some View {
        SettingsCustomRow(verticalPadding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $profile.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    TextField("Name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                TokenListEditor(
                    tokens: $profile.bundleIDs,
                    placeholder: "Bundle id — com.apple.mail, or com.google.Chrome*",
                    normalize: { $0.trimmingCharacters(in: .whitespaces) },
                    validate: { $0.contains(".") }
                )

                PromptEditor(
                    text: $profile.instructions,
                    placeholder: "How to write for this app.",
                    minHeight: 54
                )
            }
            .opacity(profile.enabled ? 1 : 0.5)
        }
    }
}

/// A plain multi-line editor with a placeholder, which `TextEditor` has no
/// notion of.
struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SettingsPalette.keycapFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(SettingsPalette.keycapBorder, lineWidth: 0.5)
        )
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

    func run(settings: SquawkSettings) {
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

            let profile = settings.profile(for: context.bundleID)
            self.report = """
                \(ContextCommand.report(context, full: true))

                ── profile
                \(profile?.name ?? "none — the base prompt and About you only")
                """
            self.isRunning = false
        }
    }
}
