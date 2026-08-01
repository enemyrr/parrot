import SwiftUI

/// One home for API keys.
///
/// They used to live inside the Cleanup pane, which was right while cleanup was
/// the only thing that had a key. It stopped being right when a transcription
/// model started needing the same OpenAI key: a credential shared by two
/// features belongs to neither of them, and the alternative — the same editor
/// rendered in both panes — makes one key look like two.
///
/// The panes that consume a key keep a one-line status of their own, so you can
/// still see whether the thing you are configuring will work from where you are
/// configuring it. What they don't keep is the editor.
struct AccountsPane: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var keys = APIKeyState()

    var body: some View {
        SettingsPage(
            title: "Accounts",
            subtitle: "Keys for the providers parrot can talk to. Nothing here is required."
        ) {
            ForEach(Keychain.Account.allCases, id: \.rawValue) { account in
                SettingsCard(
                    header: account.displayName,
                    footer: "Stored in the macOS Keychain, never in a settings file. "
                        + "\(account.envVar) is used as a fallback if no key is stored."
                ) {
                    SettingsCustomRow(verticalPadding: 12) {
                        APIKeyEditor(account: account, state: keys)
                    }
                    SettingsCustomRow(verticalPadding: 10) {
                        UsageSummary(uses: uses(of: account))
                    }
                }
            }
        }
        .onAppear { keys.refresh() }
    }

    /// What is currently pointed at this provider — not what could be. A key
    /// with nothing using it is worth showing as exactly that.
    private func uses(of account: Keychain.Account) -> [String] {
        var uses: [String] = []
        if store.settings.resolvedModel.engine == .openai, account == .openai {
            uses.append("Transcription")
        }
        if store.settings.cleanup.enabled,
           store.settings.cleanup.provider.keychainAccount == account {
            uses.append("Cleanup")
        }
        return uses
    }
}

private struct UsageSummary: View {
    let uses: [String]

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: uses.isEmpty ? "circle.dashed" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        guard !uses.isEmpty else { return "Nothing is using this provider right now." }
        return "In use by \(uses.joined(separator: " and "))."
    }
}

// MARK: - Key state

/// Tracks what the Keychain and environment currently hold. Read on demand
/// rather than cached at launch — the user may have just run
/// `parrot cleanup set-key` in a terminal.
@MainActor
final class APIKeyState: ObservableObject {
    enum Source: Equatable {
        case none
        case keychain
        case environment(String)

        var hasKey: Bool { self != .none }
    }

    @Published private(set) var sources: [String: Source] = [:]
    @Published var error: String?

    init() {
        refresh()
    }

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
        state.source(for: account).hasKey ? .ok : .warn("no key")
    }

    private var statusText: String {
        switch state.source(for: account) {
        case .none: return "No key stored."
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

// MARK: - Point-of-use status

/// The compact form the consuming panes show: whether the key that this feature
/// needs is there, and a way to go add it. Deliberately not an editor — one
/// place to type a key, several places to be told you haven't.
struct APIKeyStatusRow: View {
    let account: Keychain.Account
    /// What breaks without it, in the voice of the pane it appears in.
    let consequence: String
    @ObservedObject var state: APIKeyState

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusIndicator(status: hasKey ? .ok : .warn("no key"))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                if !hasKey {
                    Text(consequence)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(hasKey ? "Manage" : "Add a key") {
                SettingsWindowController.shared.show(pane: .accounts)
            }
            .controlSize(.small)
        }
        .onAppear { state.refresh() }
    }

    private var hasKey: Bool { state.source(for: account).hasKey }

    private var headline: String {
        switch state.source(for: account) {
        case .none: return "No \(account.displayName) API key"
        case .keychain: return "\(account.displayName) key stored in the Keychain"
        case .environment(let name): return "Using \(name) from the environment"
        }
    }
}
