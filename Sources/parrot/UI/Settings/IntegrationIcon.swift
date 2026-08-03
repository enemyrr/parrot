import AppKit
import SwiftUI

extension AppIntegration {
    /// The app behind this integration, resolved to a name and an icon.
    ///
    /// Goes through `AppCatalog` rather than doing its own Launch Services
    /// lookup: it already caches, it already handles the wildcard ids, and it
    /// already knows how to answer for something that isn't installed. It also
    /// takes the *first* of several ids that resolves, which is exactly the
    /// shape here — Cursor ships under three, and only one of them is on any
    /// given Mac.
    @MainActor
    var identity: AppIdentity {
        AppCatalog.identity(named: name, anyOf: bundleIDs)
    }

    @MainActor
    var isInstalled: Bool { identity.isInstalled }
}

/// An integration's app icon, at a size worth recognising.
///
/// An SF Symbol standing in for Slack is a `#`, and for four editors it is the
/// same `</>` four times — a list you have to read rather than one you can
/// scan. The real icons are already on disk, and they are the only thing that
/// makes this pane legible at a glance.
struct IntegrationIcon: View {
    let integration: AppIntegration
    var size: CGFloat = 26
    /// Drained of colour when the row is off, so on/off reads from across the
    /// window rather than needing every switch checked.
    var isActive = true

    var body: some View {
        Group {
            if let icon = integration.identity.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(isActive ? 1 : 0)
                    .opacity(isActive ? 1 : 0.5)
            } else {
                // Not installed. A dashed well rather than a solid one, so it
                // reads as a placeholder instead of an icon that failed to load.
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(
                        .tertiary, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])
                    )
                    .overlay(
                        Image(systemName: integration.symbol)
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
    }
}
