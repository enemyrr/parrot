import SwiftUI

/// A recording off disk, turned into text.
///
/// The one pane that isn't a setting. Everything else in this window configures
/// what happens when you hold the key; this is a thing you *do* here, so it is
/// built around a single drop target that becomes the progress and then the
/// result, rather than a form you fill in and a button you press.
struct TranscribePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var job = FileTranscriptionJob.shared

    @State private var targeted = false
    @State private var copied = false

    var body: some View {
        SettingsPage(
            title: "Transcribe a file",
            subtitle: "Any recording you already have — audio or video, any length."
        ) {
            dropZone
            optionsCard
            if case .done(let outcome) = job.state {
                result(outcome)
            }
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        Group {
            switch job.state {
            case .idle: idle
            case .running(let file, let stage): running(file: file, stage: stage)
            case .done(let outcome): finished(outcome)
            case .failed(let file, let reason): failed(file: file, reason: reason)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.08) : SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    targeted ? Color.accentColor : SettingsPalette.cardBorder,
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 0.5, dash: dash)
                )
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL), !job.isRunning else { return false }
            job.start(url: url)
            return true
        } isTargeted: { targeted = $0 }
    }

    /// Dashed only while there is nothing in it. Once a file is being worked on
    /// or a transcript is sitting there, the box holds real content and a dashed
    /// border would go on advertising an empty slot.
    private var dash: [CGFloat] {
        if case .idle = job.state { return [5, 4] }
        return []
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop a recording here")
                .font(.system(size: 13, weight: .medium))
            Text("mp3, m4a, wav, or the audio out of a video")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Choose File…") {
                if let url = FileTranscriptionJob.chooseFile() { job.start(url: url) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func running(file: String, stage: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(file)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(stage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // Without this the box jumps a pixel every time the stage line
                // changes width, which on a chunked cleanup is once a chunk.
                .frame(minHeight: 14)
            Button("Cancel") { job.cancel() }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    private func finished(_ outcome: FileTranscriptionJob.Outcome) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
            Text(outcome.source.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(summary(outcome))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Transcribe another…") {
                if let url = FileTranscriptionJob.chooseFile() { job.start(url: url) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func failed(file: String, reason: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            Text(file)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try another file…") {
                if let url = FileTranscriptionJob.chooseFile() { job.start(url: url) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func summary(_ outcome: FileTranscriptionJob.Outcome) -> String {
        var parts = [
            Self.clock(outcome.seconds),
            "\(outcome.words) words",
            String(format: "%.1fs", outcome.elapsed),
            outcome.model,
        ]
        if outcome.cleaned { parts.append("cleaned") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Options

    private var optionsCard: some View {
        SettingsCard(header: "Options", footer: modelNote) {
            SettingsRow(
                label: "Clean up afterwards",
                description: cleanupDescription
            ) {
                Toggle("", isOn: $job.cleanUp)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(cleanupUnavailable != nil)
            }
        }
    }

    private var cleanupDescription: String {
        if let why = cleanupUnavailable { return why }
        // The long transcript is the whole reason this is a per-file choice
        // rather than the dictation setting: one is a sentence, the other is
        // ten thousand words going to a provider a chunk at a time.
        return "Punctuation and paragraphs via \(store.settings.cleanup.provider.displayName), "
            + "a chunk at a time. Off by default — a long recording is a lot of text to send."
    }

    private var cleanupUnavailable: String? {
        if case .failure(let error) = makeCleaner(for: store.settings.cleanup) {
            return error.description
        }
        return nil
    }

    /// Which engine will do the work, and the one thing about it worth knowing
    /// before handing it an hour of audio.
    private var modelNote: String {
        let model = store.settings.resolvedModel
        if model.isLocal {
            return "Transcribed by \(model.displayName), on this Mac. Nothing is uploaded, "
                + "and there is no length limit — a long file is read off disk as it goes."
        }
        return "Transcribed by \(model.displayName), which means the file is uploaded and "
            + "capped at about 13 minutes. Pick a local model in Models for long recordings."
    }

    // MARK: - Result

    private func result(_ outcome: FileTranscriptionJob.Outcome) -> some View {
        SettingsSection(header: "Transcript") {
            VStack(alignment: .leading, spacing: 10) {
                // Scrolls in place only once it would otherwise stretch the
                // page. Two sentences in a fixed 260pt box is mostly empty box,
                // and an hour of transcript without one is a page you can't get
                // to the end of. Same rule `ProbeReport` follows.
                Group {
                    if outcome.text.count > 1200 {
                        ScrollView { transcript(outcome.text) }
                            .frame(height: 260)
                    } else {
                        transcript(outcome.text)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.panelCornerRadius, style: .continuous)
                        .fill(SettingsPalette.keycapFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.panelCornerRadius, style: .continuous)
                        .strokeBorder(SettingsPalette.keycapBorder, lineWidth: 0.5)
                )

                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy") { copy(outcome.text) }
                    Button("Save…") { save(outcome) }
                    Spacer()
                    Button("Clear") { job.reset() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }
        }
    }

    private func transcript(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }

    /// Prefilled with the recording's own name, in the recording's own folder —
    /// meeting.m4a becomes meeting.txt sitting next to it, one Return away,
    /// without silently overwriting anything already there.
    private func save(_ outcome: FileTranscriptionJob.Outcome) {
        let destination = outcome.defaultDestination
        let panel = NSSavePanel()
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (outcome.text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
    }
}
