import SwiftUI

/// Cleanup is the one setting that sends your words somewhere, so the pane is
/// built around making that legible: which provider, whether it runs on-device,
/// where the key lives, and exactly what the model is told to do.
struct CleanupPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var keys = APIKeyState()

    private var cleanup: CleanupSettings { store.settings.cleanup }

    var body: some View {
        SettingsPage(
            title: "Cleanup",
            subtitle: "Raw types your exact words. Cleaned runs them through a model first."
        ) {
            modeCards

            if cleanup.enabled {
                providerCard
                if cleanup.provider == .apple {
                    appleStatusCard
                } else {
                    credentialsCard
                }
                tuningCard
                promptCard
            }
        }
        .onAppear { keys.refresh() }
    }

    // MARK: - Mode

    /// The choice, shown rather than described. Both cards run the same sentence
    /// through, so the difference between them is the only thing that varies —
    /// which is far more use than a switch labelled "clean up transcripts".
    private var modeCards: some View {
        HStack(alignment: .top, spacing: 12) {
            CleanupModeCard(
                title: "Raw",
                blurb: "Typed exactly as you said it.",
                symbol: "mic.fill",
                spoken: Self.spoken,
                output: Self.spoken,
                accented: false,
                selected: !cleanup.enabled
            ) {
                store.settings.cleanup.enabled = false
            }

            CleanupModeCard(
                title: "Cleaned",
                blurb: "Punctuated, with the ums taken out.",
                symbol: "sparkles",
                spoken: Self.spoken,
                output: Self.cleaned,
                accented: true,
                selected: cleanup.enabled
            ) {
                store.settings.cleanup.enabled = true
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: cleanup.enabled)
    }

    /// One utterance with the things cleanup fixes in it — filler words, a
    /// stutter, no capitals, no punctuation. The Raw card prints it back
    /// unchanged, which is the point: dictation is a passthrough.
    private static let spoken =
        "so um i think we should ship it friday and and do the writeup"
    private static let cleaned =
        "So I think we should ship it Friday, and do the write-up."

    // MARK: - Provider

    private var providerCard: some View {
        SettingsCard(header: "Provider") {
            SettingsCustomRow(verticalPadding: 12) {
                HStack(spacing: 8) {
                    ForEach(CleanupProvider.allCases) { provider in
                        ProviderOption(
                            provider: provider,
                            selected: cleanup.provider == provider,
                            available: Self.isAvailable(provider)
                        ) {
                            store.settings.cleanup.provider = provider
                            // The model name belongs to the vendor that was
                            // selected, so carrying it across would send OpenAI
                            // a Claude id and fail every request.
                            store.settings.cleanup.model = ""
                        }
                    }
                }
            }
        }
    }

    private static func isAvailable(_ provider: CleanupProvider) -> Bool {
        provider != .apple || AppleCleanupAvailability.isAvailable
    }

    // MARK: - Apple

    private var appleStatusCard: some View {
        SettingsCard(header: "On-device model") {
            SettingsCustomRow(verticalPadding: 12) {
                HStack(alignment: .top, spacing: 9) {
                    StatusIndicator(status: appleStatus)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appleStatus == .ok
                            ? "Apple Intelligence is ready"
                            : appleStatus.message)
                            .font(.system(size: 12, weight: .medium))
                        Text(appleStatus == .ok
                            ? "Transcripts are cleaned on this Mac. Nothing is sent anywhere, "
                                + "and there is no key and no per-word cost."
                            : "Turn Apple Intelligence on in System Settings, or pick "
                                + "Anthropic or OpenAI above.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if appleStatus != .ok {
                        Button("Open Settings") {
                            PermissionActions.openAppleIntelligenceSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var appleStatus: CheckStatus {
        AppleCleanupAvailability.unavailableReason.map(CheckStatus.warn) ?? .ok
    }

    // MARK: - API credentials

    @ViewBuilder
    private var credentialsCard: some View {
        if let account = cleanup.provider.keychainAccount {
            SettingsCard(
                header: "\(account.displayName) account",
                footer: "Keys are kept in the macOS Keychain, never in a settings file. "
                    + "\(account.envVar) is used as a fallback if no key is stored."
            ) {
                SettingsCustomRow(verticalPadding: 12) {
                    APIKeyEditor(account: account, state: keys)
                }

                SettingsRow(
                    label: "Model",
                    description: "Leave empty for the default."
                ) {
                    CommittedText(text: $store.settings.cleanup.model) { draft in
                        TextField(cleanup.provider.defaultModel ?? "", text: draft)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if cleanup.provider == .openai {
                    SettingsRow(
                        label: "Reasoning effort",
                        description: "Reasoning models only. Anything above minimal "
                            + "trades latency for quality — mind the timeout."
                    ) {
                        Picker("", selection: $store.settings.cleanup.reasoningEffort) {
                            ForEach(ReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Tuning

    private var tuningCard: some View {
        SettingsCard(header: "When to run it") {
            SettingsRow(
                label: "Minimum words",
                description: "Below this, skip cleanup — “yes” doesn't need punctuation repair."
            ) {
                StepperSlider(
                    value: Binding(
                        get: { Double(store.settings.cleanup.minWords) },
                        set: { store.settings.cleanup.minWords = Int($0) }
                    ),
                    range: 0...30,
                    step: 1,
                    format: { $0 == 0 ? "always" : "\(Int($0)) words" }
                )
            }

            SettingsRow(
                label: "Timeout",
                description: "Past this, the raw transcript is typed instead."
            ) {
                StepperSlider(
                    value: $store.settings.cleanup.timeoutS,
                    range: 0.5...15,
                    step: 0.5,
                    format: { String(format: "%.1f s", $0) }
                )
            }
        }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        SettingsCard(
            header: "Instructions",
            footer: "Your vocabulary and languages are appended to whatever is here, "
                + "so a custom prompt doesn't lose them."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    CommittedText(text: $store.settings.cleanup.prompt) { draft in
                        TextEditor(text: draft)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                        .padding(7)
                        .frame(height: 130)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(SettingsPalette.cardBorder, lineWidth: 0.5)
                        )
                        .overlay(alignment: .topLeading) {
                            if store.settings.cleanup.prompt.isEmpty {
                                Text("Using the built-in prompt.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 15)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 8) {
                        Button("Load the built-in prompt") {
                            store.settings.cleanup.prompt = CleanupPrompt.base
                        }
                        .controlSize(.small)

                        Button("Reset to default") {
                            store.settings.cleanup.prompt = ""
                        }
                        .controlSize(.small)
                        .disabled(store.settings.cleanup.prompt.isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Mode card

/// One of the two ways parrot can type, with a worked example inside it.
private struct CleanupModeCard: View {
    let title: String
    let blurb: String
    let symbol: String
    /// Identical in both cards — it is the constant the comparison is made
    /// against, so it has to be visibly the same sentence.
    let spoken: String
    let output: String
    /// The cleaned card carries a warmer surface, so the two read as different
    /// kinds of thing at a glance and not just as two radio buttons.
    let accented: Bool
    let selected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                header
                transcript
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // One ring, one width. Growing the border on selection shifts every
            // pixel inside it, which is what made the two cards look misaligned
            // — only the colour changes now.
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        selected ? Color.accentColor : Color.primary.opacity(0.12)
                    )
                )
        }
    }

    /// The result on top, the thing you actually said pinned underneath — so
    /// the eye lands on what differs before what doesn't.
    ///
    /// No border of its own: nested rounded rectangles each with a hairline
    /// read as a frame inside a frame. The fill is enough to separate it.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(output)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(alignment: .top, spacing: 7) {
                MiniWaveform(tint: .secondary)
                    .padding(.top, 2)
                Text(spoken)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private var borderColor: Color {
        if selected { return .accentColor }
        return hovering ? Color.primary.opacity(0.18) : SettingsPalette.cardBorder
    }

    /// The card is the backdrop for the white transcript panel sitting on it, so
    /// it has to be darker than that panel. `controlBackgroundColor` is the same
    /// near-white as the panel in light mode, which made the panel disappear
    /// entirely on the plain card — a neutral wash is what gives it an edge.
    @ViewBuilder
    private var surface: some View {
        if accented {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(selected ? 0.18 : 0.07),
                    Color.purple.opacity(selected ? 0.13 : 0.05),
                    Color.pink.opacity(selected ? 0.10 : 0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.primary.opacity(selected ? 0.07 : 0.035)
        }
    }
}

// MARK: - Provider option

private struct ProviderOption: View {
    let provider: CleanupProvider
    let selected: Bool
    let available: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    // Unavailable is not the same as unselectable: the reason
                    // is only visible once it's picked, and hiding the option
                    // would leave the user wondering where it went.
                    if !available {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                Text(provider.blurb)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : SettingsPalette.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : SettingsPalette.keycapBorder,
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selected)
    }

    private var symbol: String {
        switch provider {
        case .apple: return "apple.logo"
        case .anthropic: return "cloud"
        case .openai: return "cloud"
        }
    }
}

// MARK: - API key

/// Tracks what the Keychain and environment currently hold. Read on demand
/// rather than cached at launch — the user may have just run
/// `parrot cleanup set-key` in a terminal.
@MainActor
final class APIKeyState: ObservableObject {
    enum Source: Equatable {
        case none
        case keychain
        case environment(String)
    }

    @Published private(set) var sources: [String: Source] = [:]
    @Published var error: String?

    func refresh() {
        for account in Keychain.Account.allCases {
            sources[account.rawValue] = Self.source(for: account)
        }
    }

    func source(for account: Keychain.Account) -> Source {
        sources[account.rawValue] ?? .none
    }

    func save(_ key: String, for account: Keychain.Account) {
        error = nil
        do {
            try Keychain.write(key, for: account)
        } catch {
            self.error = "\(error)"
        }
        refresh()
    }

    func remove(_ account: Keychain.Account) {
        error = nil
        do {
            try Keychain.delete(account)
        } catch {
            self.error = "\(error)"
        }
        refresh()
    }

    private static func source(for account: Keychain.Account) -> Source {
        if Keychain.read(account)?.isEmpty == false { return .keychain }
        if ProcessInfo.processInfo.environment[account.envVar]?.isEmpty == false {
            return .environment(account.envVar)
        }
        return .none
    }
}

private struct APIKeyEditor: View {
    let account: Keychain.Account
    @ObservedObject var state: APIKeyState

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusIndicator(status: status)
                Text(statusText)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                if case .keychain = state.source(for: account) {
                    Button("Remove") { state.remove(account) }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                SecureField("Paste a new \(account.displayName) API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var status: CheckStatus {
        switch state.source(for: account) {
        case .none: return .warn("no key")
        case .keychain, .environment: return .ok
        }
    }

    private var statusText: String {
        switch state.source(for: account) {
        case .none: return "No key — cleanup will fall back to the raw transcript."
        case .keychain: return "Key stored in the Keychain."
        case .environment(let name): return "Using \(name) from the environment."
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        state.save(key, for: account)
        draft = ""
    }
}
