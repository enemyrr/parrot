import SwiftUI

/// Setup, and the health check that used to be `parrot doctor` in a terminal.
///
/// A dialog off About rather than a sidebar row: permissions are something you
/// finish once, so a permanent row spent the sidebar's attention on a page
/// nobody opens twice.
///
/// The checks re-run on a timer while this is open. Every grant here is made in
/// System Settings, in another window, and coming back to a stale ✗ with a
/// Refresh button would be the app pretending it couldn't tell.
struct PermissionsDialog: View {
    @ObservedObject var store: SettingsStore
    let dismiss: () -> Void

    @StateObject private var checks = CheckPoller()

    var body: some View {
        SettingsDialog(
            title: "Permissions",
            subtitle: "parrot needs two grants from macOS, and one keyboard setting.",
            width: 560,
            dismiss: dismiss
        ) {
            SettingsCard(header: "Required") {
                ForEach(checks.required) { check in
                    CheckRow(check: check)
                }
            }

            SettingsCard(
                header: "Everything else",
                footer: checks.advisoryFooter
            ) {
                ForEach(checks.advisory) { check in
                    CheckRow(check: check)
                }
            }
        }
        .onAppear { checks.start(settings: store.settings) }
        .onDisappear { checks.stop() }
        .onChange(of: store.settings) { _, new in checks.refresh(settings: new) }
    }
}

private struct CheckRow: View {
    let check: Check

    var body: some View {
        SettingsCustomRow(verticalPadding: 12) {
            HStack(alignment: .top, spacing: 10) {
                StatusIndicator(status: check.status)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(check.name)
                            .font(.system(size: 13, weight: .medium))
                        if !check.status.message.isEmpty {
                            Text("— \(check.status.message)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let remediation = check.remediation {
                        Text(remediation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                action
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if check.isOK {
            EmptyView()
        } else {
            switch check.kind {
            case .microphone:
                Button("Grant") {
                    Task { await PermissionActions.requestMicrophone() }
                }
                .controlSize(.small)
            case .accessibility:
                Button("Grant") { PermissionActions.promptAccessibility() }
                    .controlSize(.small)
            case .fnKey:
                Button("Open Keyboard") { PermissionActions.openKeyboardSettings() }
                    .controlSize(.small)
            case .model, .languages, .cleanup, .squawk:
                EmptyView()
            }
        }
    }
}

/// Re-runs the checks on a slow timer. Every one of them is a cheap syscall or
/// a `defaults read`, except the Fn mapping which shells out — 2s is often
/// enough to feel immediate and rare enough to cost nothing.
@MainActor
private final class CheckPoller: ObservableObject {
    @Published private(set) var required: [Check] = []
    @Published private(set) var advisory: [Check] = []

    private var timer: Timer?
    private var settings = Settings.default

    func start(settings: Settings) {
        self.settings = settings
        refresh(settings: settings)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh(settings: self.settings)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(settings: Settings) {
        self.settings = settings
        let all = DoctorReport.run(settings: settings)
        required = all.filter { DoctorReport.requiredKinds.contains($0.kind) }
        advisory = all.filter { !DoctorReport.requiredKinds.contains($0.kind) }
    }

    var advisoryFooter: String? {
        advisory.allSatisfy(\.isOK) ? "Nothing needs attention." : nil
    }
}
