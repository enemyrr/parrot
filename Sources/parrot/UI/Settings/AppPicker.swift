import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A bundle id, resolved to the app a person recognises.
///
/// Profiles are still *stored* as bundle ids — they are stable across renames,
/// they survive an app being uninstalled, and they are the only thing that can
/// carry a wildcard. But nobody knows their apps by bundle id, so nothing above
/// the settings file should ask them to. This is the layer that turns
/// `com.tinyspeck.slackmacgap` back into Slack and its icon.
struct AppIdentity: Identifiable, Equatable {
    /// Exactly as stored, wildcard and all — this is what gets removed from the
    /// profile when the chip's × is clicked.
    let bundleID: String
    let name: String
    let icon: NSImage?
    /// False when nothing on this Mac claims the id: an app that was
    /// uninstalled, or one typed in by hand for a machine it isn't on yet.
    /// Worth showing rather than hiding — a profile that silently never matches
    /// looks like the feature is broken.
    let isInstalled: Bool

    var id: String { bundleID }

    /// True for a pattern like `com.google.Chrome*`, which claims the helper
    /// processes too and can't be resolved to one app.
    var isWildcard: Bool { bundleID.hasSuffix("*") }

    static func == (lhs: AppIdentity, rhs: AppIdentity) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name
            && lhs.isInstalled == rhs.isInstalled
    }
}

/// Looks apps up by bundle id, and asks the user to point at one.
@MainActor
enum AppCatalog {
    /// Resolution goes out to Launch Services, and SwiftUI redraws a chip row
    /// far more often than the answer can change. Cached for the life of the
    /// window; installing an app while the settings pane is open and expecting
    /// the name to appear is not a case worth invalidating for.
    private static var cache: [String: AppIdentity] = [:]

    static func identity(for bundleID: String) -> AppIdentity {
        if let hit = cache[bundleID] { return hit }
        let resolved = resolve(bundleID)
        cache[bundleID] = resolved
        return resolved
    }

    private static func resolve(_ bundleID: String) -> AppIdentity {
        // A wildcard resolves off its prefix — `com.google.Chrome*` finds
        // Chrome, which is the app the pattern is about even though the pattern
        // itself is not an id anything is registered under.
        let lookup = bundleID.hasSuffix("*") ? String(bundleID.dropLast()) : bundleID
        guard
            !lookup.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: lookup)
        else {
            return AppIdentity(
                bundleID: bundleID,
                name: fallbackName(for: lookup),
                icon: nil,
                isInstalled: false
            )
        }
        return AppIdentity(
            bundleID: bundleID,
            name: FileManager.default.displayName(atPath: url.path),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            isInstalled: true
        )
    }

    /// The first of several ids that resolves, under a name we already know.
    ///
    /// For the apps parrot excludes on its own: they ship under two or three
    /// bundle ids across versions, only one of which is installed, and the name
    /// is worth showing whether any of them is. A user with no password manager
    /// still gets to see that password managers are covered.
    static func identity(named name: String, anyOf bundleIDs: [String]) -> AppIdentity {
        for id in bundleIDs {
            let resolved = identity(for: id)
            if resolved.isInstalled { return resolved }
        }
        return AppIdentity(
            bundleID: bundleIDs.first ?? name,
            name: name,
            icon: nil,
            isInstalled: false
        )
    }

    /// The last component, which is very often the app's name anyway —
    /// `com.acme.Widget` reads as "Widget", which beats showing the whole id in
    /// a chip sized for a word.
    ///
    /// Except when that component names the category rather than the app:
    /// `com.superhuman.mail` would read as "mail", sitting in a row of email
    /// apps next to Apple's actual Mail. The vendor is the name in those, so
    /// step back one.
    private static func fallbackName(for bundleID: String) -> String {
        let parts = bundleID.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard let last = parts.last else { return bundleID }
        let generic = ["mail", "app", "desktop", "macos", "mac", "client"]
        if generic.contains(last.lowercased()), parts.count >= 2 {
            return parts[parts.count - 2].capitalized
        }
        return last
    }

    /// The Finder-style picker: opens on /Applications, takes a selection, and
    /// hands back what it could read a bundle id out of.
    ///
    /// Multiple selection on purpose — "Slack & Discord" is one profile with two
    /// apps in it, and adding them one modal at a time is the sort of thing that
    /// makes people leave the defaults alone.
    static func choose(message: String = "Choose the apps this style should apply to.")
        -> [AppIdentity]
    {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // An .app *is* a directory. Without this the panel walks into it and
        // the user ends up picking a binary out of Contents/MacOS.
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = message

        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            cache[id] = AppIdentity(
                bundleID: id,
                name: FileManager.default.displayName(atPath: url.path),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                isInstalled: true
            )
            return cache[id]
        }
    }
}

// MARK: - Views

/// An app's icon at a settings-row size, or a neutral placeholder when the app
/// isn't installed.
struct AppIcon: View {
    let identity: AppIdentity
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = identity.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The apps a profile claims, as removable chips, with a split button that adds
/// more — by picking them, or by bundle id for the cases picking can't cover.
struct AppChipList: View {
    @Binding var bundleIDs: [String]
    /// Apps the list contains but the user cannot take out of it. Shown in the
    /// same row as the rest, with a lock instead of an ×: leaving them out
    /// entirely would make the list look like the whole story when it isn't,
    /// and putting them in a separate box asks the reader to work out why.
    var locked: [AppIdentity] = []
    var lockedHelp = "Always excluded"
    var addLabel = "Add apps…"
    var pickerMessage = "Choose the apps this style should apply to."

    @State private var typing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !locked.isEmpty || !bundleIDs.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(locked) { identity in
                        AppChip(identity: identity, lockedHelp: lockedHelp)
                    }
                    // Keyed and removed by value: two removals in one frame
                    // would trap on a captured index.
                    ForEach(bundleIDs, id: \.self) { id in
                        AppChip(identity: AppCatalog.identity(for: id)) {
                            bundleIDs.removeAll { $0 == id }
                        }
                    }
                }
            }

            if typing {
                HStack(spacing: 6) {
                    TextField("com.example.App, or com.example.App*", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit(commitDraft)
                    Button("Add", action: commitDraft)
                        .disabled(!isValid(draft))
                    Button("Cancel") {
                        typing = false
                        draft = ""
                    }
                }
            } else {
                // A split button rather than two: picking is what almost
                // everyone wants, and the bundle id field is for wildcards and
                // for apps that aren't installed on this Mac — real, rare, and
                // not worth the width when it isn't being used.
                Menu {
                    Button("Enter a bundle id…") { typing = true }
                } label: {
                    Label(addLabel, systemImage: "plus")
                } primaryAction: {
                    add(AppCatalog.choose(message: pickerMessage))
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
    }

    private func add(_ found: [AppIdentity]) {
        for identity in found where !bundleIDs.contains(identity.bundleID) {
            bundleIDs.append(identity.bundleID)
        }
    }

    private func commitDraft() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard isValid(value), !bundleIDs.contains(value) else {
            draft = ""
            typing = false
            return
        }
        bundleIDs.append(value)
        draft = ""
        typing = false
    }

    private func isValid(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).contains(".")
    }
}

private struct AppChip: View {
    let identity: AppIdentity
    /// Nil for a chip that can't be removed — the × becomes a lock, and the
    /// tooltip says why rather than leaving a dead-looking chip to explain
    /// itself.
    var remove: (() -> Void)?
    var lockedHelp = ""

    @State private var hovering = false

    private var isLocked: Bool { remove == nil }

    var body: some View {
        HStack(spacing: 5) {
            AppIcon(identity: identity, size: 14)
            Text(identity.name)
                .font(.system(size: 11, weight: .medium))
            if identity.isWildcard {
                // The pattern is the point of the chip — without it, Chrome and
                // Chrome* look identical while behaving differently.
                Text("＊")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? .primary : .secondary)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(SettingsPalette.chipFill))
        // Locked chips read as settled rather than broken: dimmed like an
        // uninstalled app, but never below it.
        .opacity(identity.isInstalled ? (isLocked ? 0.75 : 1) : 0.55)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        if isLocked {
            return identity.isInstalled
                ? "\(lockedHelp) — \(identity.bundleID)"
                : lockedHelp
        }
        return identity.isInstalled
            ? identity.bundleID
            : "\(identity.bundleID) — not installed on this Mac"
    }
}
