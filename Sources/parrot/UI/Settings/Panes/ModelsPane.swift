import AppKit
import SwiftUI

/// Where models are chosen and fetched.
///
/// This pane is the reason the recording pill no longer doubles as a download
/// HUD: a 460 MB fetch needs somewhere it can show a real progress bar, a size,
/// a failure with a retry, and a way to get the space back — none of which fit
/// in a capsule at the bottom of the screen.
struct ModelsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var context: SettingsContext

    @State private var deleteCandidate: TranscriptionModel?

    var body: some View {
        SettingsPage(
            title: "Models",
            subtitle: "Transcription runs entirely on this Mac, on the Neural Engine."
        ) {
            SettingsCard(header: "Available") {
                ForEach(ModelRegistry.shared, id: \.id) { model in
                    ModelRow(
                        model: model,
                        state: catalog.state(for: model),
                        // Resolved, so a settings blob naming a retired model
                        // still marks the model actually in use — otherwise no
                        // row shows as active and the running one offers a
                        // Delete button.
                        isActive: store.settings.resolvedModel.id == model.id,
                        engineStatus: context.engineStatus,
                        select: { select(model) },
                        download: { catalog.download(model) },
                        cancel: { catalog.cancelDownload(model) },
                        delete: { deleteCandidate = model }
                    )
                }
            }

            storageCard
        }
        .onAppear { catalog.refresh() }
        .alert(
            "Delete \(deleteCandidate?.displayName ?? "")?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { model in
            Button("Delete", role: .destructive) { delete(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("The files come back the next time you select it — "
                + "that's another \(model.sizeMB) MB download.")
        }
    }

    private var storageCard: some View {
        SettingsCard(header: "Storage") {
            SettingsRow(
                label: "Downloaded models",
                description: catalog.totalInstalledBytes > 0
                    ? "\(catalog.totalInstalledBytes.formattedBytes) on disk"
                    : "Nothing downloaded yet",
                wideControl: true
            ) {
                Button("Reveal in Finder") {
                    let directory = store.settings.resolvedModel.cacheDirectory
                    NSWorkspace.shared.selectFile(
                        directory.path,
                        inFileViewerRootedAtPath: directory.deletingLastPathComponent().path
                    )
                }
                .disabled(catalog.totalInstalledBytes == 0)
            }
        }
    }

    /// Picking a model that isn't on disk starts fetching it. Making the user
    /// select and *then* find a Download button would be two steps to express
    /// one intent.
    private func select(_ model: TranscriptionModel) {
        store.settings.model = model.id
        if case .notInstalled = catalog.state(for: model) {
            catalog.download(model)
        }
    }

    private func delete(_ model: TranscriptionModel) {
        do {
            try catalog.delete(model)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't delete \(model.displayName)"
            alert.runModal()
        }
        deleteCandidate = nil
    }
}

private struct ModelRow: View {
    let model: TranscriptionModel
    let state: ModelState
    let isActive: Bool
    let engineStatus: SettingsContext.EngineStatus
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        SettingsCustomRow(verticalPadding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 11) {
                    SelectionMark(selected: isActive)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            if model.recommended {
                                Badge(text: "Recommended", tint: .accentColor)
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    trailing
                }

                if case .downloading(let fraction, let phase) = state {
                    DownloadProgressBar(fraction: fraction, phase: phase, cancel: cancel)
                }

                if case .failed(let message) = state {
                    FailureNotice(message: message, retry: download)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
        }
        .background(hovering && !isActive ? Color.primary.opacity(0.03) : .clear)
    }

    private var subtitle: String {
        var parts = [languageLabel]
        switch state {
        case .installed(let bytes):
            parts.append(bytes.map(\.formattedBytes) ?? "\(model.sizeMB) MB")
        case .notInstalled, .failed:
            parts.append("\(model.sizeMB) MB download")
        case .downloading:
            break
        }
        if isActive, case .ready(let id) = engineStatus, id == model.id {
            parts.append("loaded")
        }
        return parts.joined(separator: " · ")
    }

    private var languageLabel: String {
        model.languages == ["multi"] ? "25 languages" : model.languages.joined(separator: ", ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .notInstalled, .failed:
            Button("Download", action: download)
                .controlSize(.small)
        case .downloading:
            EmptyView()
        case .installed:
            HStack(spacing: 8) {
                if isActive {
                    // The active model has no Delete button on purpose: removing
                    // the files out from under a loaded engine leaves parrot in a
                    // state it can't dictate its way out of. Switching first is
                    // the only safe order, so the UI only offers that one.
                    Text("In use")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete the downloaded files")
                }
            }
        }
    }
}

private struct SelectionMark: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    selected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: selected ? 5 : 1
                )
                .frame(width: 14, height: 14)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}

private struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct DownloadProgressBar: View {
    let fraction: Double
    let phase: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.25), value: fraction)

            Text("\(phase) · \(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .trailing)

            Button("Cancel", action: cancel)
                .controlSize(.small)
        }
        .padding(.leading, 25)
    }
}

private struct FailureNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Retry", action: retry)
                .controlSize(.small)
        }
        .padding(.leading, 25)
    }
}
