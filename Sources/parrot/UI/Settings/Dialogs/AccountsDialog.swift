import SwiftUI

/// One home for API keys.
///
/// They used to live inside the Cleanup pane, which was right while cleanup was
/// the only thing that had a key. It stopped being right when a transcription
/// model started needing the same OpenAI key: a credential shared by two
/// features belongs to neither of them, and the alternative — the same editor
/// rendered in both panes — makes one key look like two.
///
/// A dialog off About rather than a sidebar row, for the same reason
/// Permissions is one: pasting a key is something you do once, so a permanent
/// row spent the sidebar's attention on a page nobody opens twice. The places
/// that consume a key keep a one-line status of their own, and that status is
/// what opens this — so the way in is always where you noticed the key was
/// missing.
struct AccountsDialog: View {
    @ObservedObject var store: SettingsStore
    let dismiss: () -> Void

    @StateObject private var keys = APIKeyState()

    var body: some View {
        SettingsDialog(
            title: "Accounts",
            subtitle: "Keys for the providers parrot can talk to. Nothing here is required.",
            width: 560,
            dismiss: dismiss
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

    /// The line the About row shows, so the dialog is only worth opening when
    /// it doesn't already say what you wanted to know.
    static var summary: String {
        let stored = Keychain.Account.allCases.filter { APIKeyState.source(for: $0).hasKey }
        guard !stored.isEmpty else {
            return "No keys stored. Only the cloud models need one."
        }
        return "\(stored.map(\.displayName).formatted(.list(type: .and))) "
            + (stored.count == 1 ? "is set up." : "are set up.")
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
    /// Per account, not one shared string: every provider has its own editor on
    /// screen, and a Keychain failure shown under all of them names the wrong
    /// one three times.
    @Published private(set) var errors: [String: String] = [:]

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

    func error(for account: Keychain.Account) -> String? {
        errors[account.rawValue]
    }

    func save(_ key: String, for account: Keychain.Account) {
        errors[account.rawValue] = nil
        do {
            try Keychain.write(key, for: account)
        } catch {
            errors[account.rawValue] = "\(error)"
        }
        refresh()
    }

    func remove(_ account: Keychain.Account) {
        errors[account.rawValue] = nil
        do {
            try Keychain.delete(account)
        } catch {
            errors[account.rawValue] = "\(error)"
        }
        refresh()
    }

    static func source(for account: Keychain.Account) -> Source {
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

            if let error = state.error(for: account) {
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
///
/// It opens the editor as a sheet on itself rather than sending you to another
/// page: you noticed the key was missing here, so here is where you should be
/// able to fix it and carry on with whatever you were setting up.
struct APIKeyStatusRow: View {
    let account: Keychain.Account
    /// What breaks without it, in the voice of the pane it appears in.
    let consequence: String
    @ObservedObject var state: APIKeyState

    @State private var editing = false

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
            Button(hasKey ? "Manage" : "Add a key") { editing = true }
                .controlSize(.small)
        }
        .onAppear { state.refresh() }
        .sheet(isPresented: $editing) {
            state.refresh()
        } content: {
            AccountsDialog(store: SettingsStore.shared) { editing = false }
        }
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
