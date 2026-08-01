import SwiftUI

/// The sections in the sidebar, in order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case models
    case cleanup
    case dictionary
    case appearance
    case accounts
    case history
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .cleanup: return "Cleanup"
        case .dictionary: return "Dictionary"
        case .appearance: return "Appearance"
        case .accounts: return "Accounts"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .models: return "waveform"
        case .cleanup: return "sparkles"
        case .dictionary: return "character.book.closed"
        case .appearance: return "paintbrush"
        case .accounts: return "key"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        case .about: return "bird"
        }
    }

    /// Sidebar grouping. Setup lives apart from preferences because it is
    /// something you finish, not something you tune.
    enum Group: String, CaseIterable, Identifiable {
        case dictation = "Dictation"
        case system = "System"

        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .general, .models, .cleanup, .dictionary, .appearance: return .dictation
        // Accounts sits with the system settings, not with Dictation: it is
        // setup you finish once, not a dial you turn while tuning how parrot
        // types.
        case .accounts, .history, .permissions, .about: return .system
        }
    }

    static func panes(in group: Group) -> [SettingsPane] {
        allCases.filter { $0.group == group }
    }
}

/// Everything the settings window needs from a running daemon.
///
/// All of it is optional: `parrot settings` opens the same window with no
/// daemon behind it, and every pane still shows and saves settings. Only the
/// bits that need a live engine — the model's load state, the overlay preview —
/// go quiet.
@MainActor
final class SettingsContext: ObservableObject {
    enum EngineStatus: Equatable {
        case notRunning
        case loading(String)
        case ready(String)
        case failed(String)
    }

    @Published var engineStatus: EngineStatus = .notRunning

    /// Owned by the daemon, not by the pane that asks for a preview: dictation
    /// takes the microphone back whenever the hotkey is pressed, and a pane
    /// holding its own flag would go on offering "Stop preview" for something
    /// that already stopped.
    @Published var isPreviewing = false

    /// Show the recording pill with the given look so the user can judge it
    /// against their own voice, rather than against a static swatch.
    var startOverlayPreview: ((OverlayStyle, Double) -> Void)?
    var updateOverlayPreview: ((OverlayStyle, Double) -> Void)?
    var endOverlayPreview: (() -> Void)?

    var isLive: Bool { startOverlayPreview != nil }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext
    @State var pane: SettingsPane

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 188, ideal: 196, max: 240)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 520, ideal: 600)
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private var sidebar: some View {
        List(selection: $pane) {
            ForEach(SettingsPane.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(SettingsPane.panes(in: group)) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EngineStatusBar(status: context.engineStatus)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general:
            GeneralPane(store: store)
        case .models:
            ModelsPane(store: store, catalog: catalog, context: context)
        case .cleanup:
            CleanupPane(store: store)
        case .dictionary:
            DictionaryPane(store: store)
        case .appearance:
            AppearancePane(store: store, context: context)
        case .accounts:
            AccountsPane(store: store)
        case .history:
            HistoryPane(store: store)
        case .permissions:
            PermissionsPane(store: store)
        case .about:
            AboutPane()
        }
    }
}

/// A permanent one-line answer to "is it actually working right now?", pinned
/// under the sidebar. Without it the window can only report on settings, never
/// on the thing the settings configure.
private struct EngineStatusBar: View {
    let status: SettingsContext.EngineStatus

    var body: some View {
        HStack(spacing: 7) {
            indicator
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 8, height: 8)
        case .notRunning:
            Circle().fill(.tertiary).frame(width: 7, height: 7)
        case .ready:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(.red).frame(width: 7, height: 7)
        }
    }

    private var label: String {
        switch status {
        case .notRunning: return "Not running"
        case .loading(let what): return what
        case .ready(let model): return "Ready · \(model)"
        case .failed(let why): return why
        }
    }
}
