import SwiftUI

/// Which microphone recordings come from. Same list as the menu bar's
/// submenu — the window shouldn't be the one place you can't answer it.
struct MicrophoneDialog: View {
    @ObservedObject var store: SettingsStore
    let dismiss: () -> Void

    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefault: AudioInputDevice?

    private var selected: String { store.settings.audio.inputDeviceUID }

    var body: some View {
        SettingsDialog(
            title: "Microphone",
            subtitle: "Recordings come from this input, whatever the rest of the Mac is using.",
            dismiss: dismiss
        ) {
            SettingsCard(footer: footer) {
                choice(
                    name: "System Default",
                    detail: systemDefault?.name ?? "No input device",
                    uid: ""
                )

                ForEach(devices) { device in
                    choice(name: device.name, detail: nil, uid: device.uid)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func choice(name: String, detail: String?, uid: String) -> some View {
        Button {
            store.settings.audio.inputDeviceUID = uid
        } label: {
            // The same mark the model list uses: one list of one-of-N choices a
            // click away from another shouldn't disagree about what "picked"
            // looks like.
            HStack(spacing: 11) {
                SelectionMark(selected: selected == uid)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A chosen device that isn't plugged in gets said out loud: capture falls
    /// back to the default, and without this the list would show a tick against
    /// nothing and look like the setting had lost itself.
    private var footer: String? {
        guard !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) else {
            return nil
        }
        return "⚠ The microphone you chose isn't connected. Recordings use the "
            + "system default until it's back."
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        systemDefault = AudioDevices.systemDefaultInput()
    }
}

/// One line for the fundamentals row and the menu bar to agree on.
enum MicrophoneSummary {
    static func describe(uid: String) -> String {
        guard !uid.isEmpty else {
            let name = AudioDevices.systemDefaultInput()?.name
            return name.map { "System Default (\($0))" } ?? "System Default"
        }
        guard let device = AudioDevices.device(uid: uid) else {
            return "Chosen microphone unavailable — using the default"
        }
        return device.name
    }
}
