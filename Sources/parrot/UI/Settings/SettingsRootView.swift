import SwiftUI

/// The sections in the sidebar, in order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case home
    case squawk
    case models
    case cleanup
    case style
    case dictionary
    case integrations
    case accounts
    case history
    case usage
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .squawk: return "Squawk"
        case .models: return "Models"
        case .cleanup: return "Cleanup"
        case .style: return "Style"
        case .dictionary: return "Dictionary"
        case .integrations: return "Integrations"
        case .accounts: return "Accounts"
        case .history: return "History"
        case .usage: return "Usage"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .squawk: return "sparkles"
        case .models: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .style: return "person.wave.2"
        case .dictionary: return "character.book.closed"
        case .integrations: return "square.on.square.dashed"
        case .accounts: return "key"
        case .history: return "clock.arrow.circlepath"
        case .usage: return "chart.bar"
        case .permissions: return "lock.shield"
        case .about: return "bird"
        }
    }

    /// About is reachable from the parrot glyph under the sidebar, and
    /// Permissions and Accounts are sheets on it — none is a row of its own,
    /// because none is somewhere you navigate to while tuning.
    static var visible: [SettingsPane] {
        allCases.filter { !$0.isHidden }
    }

    /// Still cases, because `parrot settings <name>` and the menu bar name
    /// them — permissions and accounts land on About with their sheet up, and
    /// history, models and usage land on Home, where the transcripts, the model
    /// row and the totals live now.
    var isHidden: Bool {
        switch self {
        case .about, .permissions, .accounts, .history, .models, .usage: return true
        default: return false
        }
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
    var startOverlayPreview: ((Double) -> Void)?
    var updateOverlayPreview: ((Double) -> Void)?
    var endOverlayPreview: (() -> Void)?

    var isLive: Bool { startOverlayPreview != nil }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext
    @State private var pane: SettingsPane
    /// One-shot: the pane clears it once it has opened the sheet. A constant
    /// would re-open the sheet every time that pane is navigated back to, since
    /// leaving it discards the @State that tracks it.
    @State private var openAboutDialog: AboutPane.Dialog?
    @State private var openModels: Bool

    init(
        store: SettingsStore,
        catalog: ModelCatalog,
        context: SettingsContext,
        pane: SettingsPane
    ) {
        self.store = store
        self.catalog = catalog
        self.context = context
        // Permissions and Accounts are sheets on About now, so a request for
        // either selects About and opens the sheet rather than showing a pane
        // with no row. History, Models and Usage live on Home, so a request for
        // any of them lands there.
        let landing: SettingsPane = switch pane {
        case .permissions, .accounts: .about
        case .history, .models, .usage: .home
        default: pane
        }
        let aboutDialog: AboutPane.Dialog? = switch pane {
        case .permissions: .permissions
        case .accounts: .accounts
        default: nil
        }
        _pane = State(initialValue: landing)
        _openAboutDialog = State(initialValue: aboutDialog)
        _openModels = State(initialValue: pane == .models)
    }

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
            ForEach(SettingsPane.visible) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EngineStatusBar(status: context.engineStatus) { pane = .about }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .home, .history, .models, .usage:
            HomePane(
                store: store,
                catalog: catalog,
                context: context,
                openModels: $openModels
            )
        case .squawk:
            SquawkPane(store: store)
        case .cleanup:
            CleanupPane(store: store)
        case .style:
            StylePane(store: store)
        case .dictionary:
            DictionaryPane(store: store)
        case .integrations:
            IntegrationsPane(store: store)
        case .permissions, .accounts, .about:
            AboutPane(store: store, openDialog: $openAboutDialog)
        }
    }
}

/// A permanent one-line answer to "is it actually working right now?", pinned
/// under the sidebar. Without it the window can only report on settings, never
/// on the thing the settings configure.
private struct EngineStatusBar: View {
    let status: SettingsContext.EngineStatus
    let onAbout: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            indicator
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            aboutButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutButton: some View {
        Button(action: onAbout) {
            Group {
                if let glyph = ParrotGlyph.image(size: 15) {
                    Image(nsImage: glyph)
                } else {
                    Image(systemName: "bird")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("About parrot")
        .accessibilityLabel("About parrot")
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
        case .ready: return "Ready"
        case .failed(let why): return why
        }
    }
}
