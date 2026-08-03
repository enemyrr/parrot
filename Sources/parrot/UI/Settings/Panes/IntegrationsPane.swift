import AppKit
import SwiftUI

/// The apps parrot knows how to read names out of, and whether each of them is
/// actually working right now.
///
/// The second half is the reason this is a pane rather than three toggles in
/// the Dictionary. Every integration in here is a set of guesses about how one
/// app lays its window out, and an app is free to change that in any release —
/// so the honest thing to show is not a list of features but a list of
/// findings, with the ones that have stopped working marked as such.
struct IntegrationsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var monitor: IntegrationMonitor = .shared
    @StateObject private var probe = IntegrationProbe()

    private var settings: IntegrationSettings { store.settings.integrations }

    var body: some View {
        SettingsPage(
            title: "App integrations",
            subtitle: "Say a name out loud and get the thing the app actually links."
        ) {
            enableCard

            if settings.enabled {
                appsCard
                behaviourCard
                checkCard
            }
        }
    }

    /// Always on the page, never only in the off state. The switch used to live
    /// in a card shown *because* the feature was off, so turning it on removed
    /// the only control that could turn it back off again.
    private var enableCard: some View {
        SettingsCard(
            footer: settings.enabled
                ? nil
                : "Off, nothing walks a window: dictation goes on reading exactly one thing "
                    + "about the app in front, which is its bundle id."
        ) {
            SettingsRow(
                label: settings.enabled
                    ? "App integrations are on"
                    : "App integrations are off",
                description: "parrot reads the names on screen — channels, people, "
                    + "filenames — while you talk."
            ) {
                Toggle("", isOn: $store.settings.integrations.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Apps

    private var appsCard: some View {
        SettingsCard(
            header: "Apps",
            footer: "An integration that comes back empty three times in a row switches "
                + "itself off and says so here, rather than costing part of every "
                + "dictation forever. It tries again when the app restarts."
        ) {
            ForEach(AppIntegrations.all) { integration in
                SettingsCustomRow(verticalPadding: 9) {
                    IntegrationRow(
                        integration: integration,
                        state: monitor.state(for: integration.id),
                        // Not being installed outranks anything the monitor
                        // knows: an app that isn't here has never been read, and
                        // "Unavailable" on a row for an app you don't own reads
                        // as a bug in parrot.
                        unavailable: integration.isInstalled
                            ? monitor.availability(for: integration, settings: settings)
                            : .notInstalled,
                        isOn: Binding(
                            get: { settings.isEnabled(integration.id) },
                            set: { store.settings.integrations.setEnabled($0, for: integration.id) }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Behaviour

    private var behaviourCard: some View {
        SettingsCard(
            header: "What it does with them",
            footer: "Tagging is a literal table lookup, not a model: what comes out is "
                + "always something that was on your screen. Nothing here reaches history."
        ) {
            SettingsRow(
                label: "Tag names you point at",
                description: "“hashtag eng parrot” → #eng-parrot. “at sara” → @Sara. "
                    + "Nothing fires unless you say the trigger word."
            ) {
                Toggle("", isOn: $store.settings.integrations.tagMentions)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRow(
                label: "Spell identifiers",
                description: "“use effect” → useEffect, in an editor. The one rewrite with "
                    + "no trigger word in front of it, so it's the one to turn off first "
                    + "if it fires when you didn't mean it."
            ) {
                Toggle("", isOn: $store.settings.integrations.spellSymbols)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRow(
                label: "Hint the transcriber",
                description: "Hands the names to the model as vocabulary. This is what "
                    + "makes tagging land — a rule for “eng parrot” never fires if the "
                    + "decoder wrote “ang parrot”."
            ) {
                Toggle("", isOn: $store.settings.integrations.learnVocabulary)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Check

    private var checkCard: some View {
        SettingsCard(
            header: "Check",
            footer: "Switch to the app you want to test — Slack, Cursor — and leave it in "
                + "front. parrot reads it \(Int(IntegrationProbe.delay)) seconds later and "
                + "shows what it found."
        ) {
            SettingsCustomRow(verticalPadding: 10) {
                HStack(spacing: 10) {
                    Button(probe.isRunning ? "Reading…" : "Check the app in front") {
                        probe.run(settings: settings)
                    }
                    .controlSize(.small)
                    .disabled(probe.isRunning)

                    if probe.isRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }

                    Spacer()

                    Button("Try all again") { monitor.reset() }
                        .controlSize(.small)
                        .help("Clears every “unavailable” mark so each app gets read once more.")
                }
            }

            if let report = probe.report {
                SettingsCustomRow(verticalPadding: 10) {
                    ProbeReport(text: report)
                }
            }
        }
    }
}

// MARK: - Row

/// One app: its icon, what it does, whether it's working, and its switch.
private struct IntegrationRow: View {
    let integration: AppIntegration
    let state: IntegrationMonitor.State
    let unavailable: IntegrationUnavailable?
    @Binding var isOn: Bool

    /// Live and switched on. Everything visual keys off this rather than off
    /// `isOn` alone, so a row for an app you don't have doesn't look armed.
    private var isActive: Bool { isOn && unavailable != .notInstalled }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            IntegrationIcon(integration: integration, size: 27, isActive: isActive)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(integration.name)
                        .font(.system(size: 13, weight: .medium))
                    badge
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(unavailable == .notInstalled)
        }
        .opacity(isActive ? 1 : 0.62)
    }

    /// Only ever shown for something worth acting on. A row with no badge is
    /// one that is either working or has simply not been used yet, and a
    /// "Ready" badge on every line is a wall of green that says nothing.
    @ViewBuilder
    private var badge: some View {
        if let unavailable, unavailable != .off {
            // Not-installed is a fact about the Mac, not a fault: grey. The
            // rest are things that could be fixed, and those are worth a colour
            // that carries across the room.
            let isFault = unavailable != .notInstalled
            Pill(
                text: unavailable.badge,
                tint: isFault ? .orange : .secondary,
                filled: isFault
            )
        } else if state.entityCount > 0, unavailable == nil {
            Pill(text: "\(state.entityCount) names", tint: .green, filled: true)
        }
    }

    private var detail: String {
        if let unavailable, unavailable != .off {
            return unavailable.explanation
        }
        return integration.blurb
    }
}

/// A small status capsule. Colour is doing the work here, so the two states it
/// can be in are deliberately far apart rather than two shades of one hue.
private struct Pill: View {
    let text: String
    let tint: Color
    var filled = true

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(filled ? tint.opacity(0.15) : Color.clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color.clear : tint.opacity(0.35), lineWidth: 0.5
                )
            )
    }
}

// MARK: - Probe

/// Reads whatever is in front, on a delay, and reports what a roster would have
/// found there.
///
/// The delay is the whole design: the thing being measured is another app's
/// window, and bringing the settings window forward to press a button changes
/// it. Same reason and same shape as squawk's context inspector.
@MainActor
private final class IntegrationProbe: ObservableObject {
    static let delay: TimeInterval = 4

    @Published var report: String?
    @Published var isRunning = false

    func run(settings: IntegrationSettings) {
        guard !isRunning else { return }
        isRunning = true
        report = nil

        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.delay * 1_000_000_000))
            defer { isRunning = false }

            guard let target = AppTarget.frontmost() else {
                report = "No app in front to read."
                return
            }
            guard let integration = AppIntegrations.integration(for: target.bundleID) else {
                report = "\(target.name) (\(target.bundleID ?? "no bundle id"))\n"
                    + "No integration claims this app."
                return
            }

            let roster = await Task.detached(priority: .userInitiated) {
                RosterReader.read(target, integration: integration)
            }.value

            IntegrationMonitor.shared.record(
                roster, integrationID: integration.id, pid: target.pid
            )
            report = Self.describe(roster, integration: integration)
        }
    }

    /// The names themselves, not just a count. A count says the walk ran; the
    /// names say whether it found the right things — which is the only question
    /// anyone opens this for.
    private static func describe(_ roster: AppRoster, integration: AppIntegration) -> String {
        var lines = ["\(integration.name) · \(roster.summary)"]
        if let unavailable = roster.unavailable {
            lines.append(unavailable.explanation)
            return lines.joined(separator: "\n")
        }
        if let note = roster.note { lines.append(note) }
        for kind in AppEntity.Kind.allCases {
            let found = roster.entities(of: kind)
            guard !found.isEmpty else { continue }
            let sample = found.prefix(12).map(\.literal).joined(separator: "  ")
            lines.append("\n\(kind.pluralName) (\(found.count))\n\(sample)"
                + (found.count > 12 ? "  …" : ""))
        }
        return lines.joined(separator: "\n")
    }
}
