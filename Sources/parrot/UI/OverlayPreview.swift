import AppKit
import ArgumentParser
import Foundation

/// Live overlay preview driven by the real microphone.
///
/// The visualisers are hard to judge against synthetic audio — you need to see
/// how they respond to your own cadence, plosives and pauses. This opens the
/// pill, feeds it real levels, and lets you flip between modes in place so the
/// comparison is against the same voice rather than the same recording.
struct OverlayPreview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay-preview",
        abstract: "Preview the recording overlay against your live microphone.",
        discussion: """
            Press 1/2 to switch mode (dictate / squawk), +/- to trim \
            sensitivity, l to toggle the hands-free lock, t to preview the \
            transcribing spinner, q to quit.
            """
    )

    @Option(name: .long, help: "Mode to start on: dictate or squawk.")
    var mode: String = "dictate"

    @Option(name: .long, help: "Meter sensitivity to start on (0.25–3.0).")
    var sensitivity: Double?

    func run() throws {
        guard let initial = DictationMode(rawValue: mode) else {
            throw ValidationError("Unknown mode '\(mode)'. Use dictate or squawk.")
        }
        // Start from the user's own settings unless overridden, so what you see
        // here is what the daemon will actually do.
        let startSensitivity = sensitivity ?? SettingsStore.current().overlay.sensitivity

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let capture = AudioCapture()
        let overlay = MainActor.assumeIsolated {
            RecordingOverlay(sensitivity: startSensitivity)
        }
        capture.onLevel = { level in overlay.pushLevel(level) }

        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("Could not start audio capture: \(error)\n".utf8))
            throw ExitCode(1)
        }

        // Mode and state are both live knobs here, and `show` takes them
        // together — so the one the keypress doesn't change has to be carried.
        var mode = initial
        var state = RecordingOverlay.State.recording

        MainActor.assumeIsolated { overlay.show(state, mode: mode) }
        print(Self.banner(initial, startSensitivity))

        readKeys { key in
            MainActor.assumeIsolated {
                switch key {
                case "1": mode = .dictate; overlay.show(state, mode: mode); print("→ dictate")
                case "2": mode = .squawk; overlay.show(state, mode: mode); print("→ squawk")
                case "l": state = .latched; overlay.show(state, mode: mode); print("→ latched")
                case "r": state = .recording; overlay.show(state, mode: mode); print("→ recording")
                case "t": state = .transcribing; overlay.show(state, mode: mode); print("→ transcribing")
                case "d":
                    Self.toggleReadout(overlay)
                case "+", "=", "-", "_":
                    let step = (key == "+" || key == "=") ? 0.1 : -0.1
                    overlay.setSensitivity(overlay.sensitivity + step)
                    print(String(format: "→ sensitivity %.2f", overlay.sensitivity))
                case "q", "\u{03}", "\u{04}":
                    overlay.hide()
                    capture.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                default: break
                }
            }
        }

        app.run()
    }

    private static var readoutTimer: Timer?

    /// Prints what the meter is actually seeing — input level, the room floor
    /// it has learned, and the resulting bar height. Beats guessing at whether
    /// "too sensitive" means the floor or the curve.
    @MainActor
    private static func toggleReadout(_ overlay: RecordingOverlay) {
        if let timer = readoutTimer {
            timer.invalidate()
            readoutTimer = nil
            print("→ levels off")
            return
        }
        print("→ levels on   in / room-floor / gate → meter")
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let r = overlay.readout
                let filled = Int((r.level * 20).rounded())
                let bar = String(repeating: "█", count: filled)
                    + String(repeating: "·", count: 20 - filled)
                print(String(
                    format: "%6.1f dB  room %6.1f  gate %6.1f  %@ %.2f",
                    r.db, r.noiseFloor, r.floor, bar, r.level
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        readoutTimer = timer
    }

    private static func banner(_ mode: DictationMode, _ sensitivity: Double) -> String {
        """
        Listening — talk at it. Mode '\(mode.rawValue)', \
        sensitivity \(String(format: "%.2f", sensitivity)).
          1 dictate   2 squawk
          r recording   l latched   t transcribing
          + / -  sensitivity (higher picks up quieter speech)
          d live level readout
          q quit
        """
    }

    /// Raw-mode stdin so single keypresses arrive without a newline.
    private func readKeys(_ handler: @escaping (Character) -> Void) {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        var mode = raw
        mode.c_lflag &= ~UInt(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &mode)
        let restore = raw
        atexit_b { var r = restore; tcsetattr(STDIN_FILENO, TCSANOW, &r) }

        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF (stdin closed or /dev/null) — otherwise this spins on empties.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for character in text {
                DispatchQueue.main.async { handler(character) }
            }
        }
    }
}
