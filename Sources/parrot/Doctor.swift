import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum CheckStatus: Equatable {
    case ok
    case warn(String)
    case fail(String)

    /// Text for the status line. Empty for a pass — the row's own label plus a
    /// tick says everything there is to say.
    var message: String {
        switch self {
        case .ok: return ""
        case .warn(let m), .fail(let m): return m
        }
    }
}

/// Which check this is, so the UI can offer the right button next to it.
/// Matching on a message string would break the moment one is reworded.
enum CheckKind: String, Equatable {
    case microphone
    case accessibility
    case fnKey
    case model
    case languages
    case cleanup
}

struct Check: Identifiable, Equatable {
    let kind: CheckKind
    let name: String
    let status: CheckStatus
    let remediation: String?

    var id: String { kind.rawValue }

    var isOK: Bool { status == .ok }
}

enum DoctorReport {
    static func run(settings: Settings) -> [Check] {
        [
            checkMicrophone(),
            checkAccessibility(),
            checkFnKeyMapping(settings),
            checkModel(settings),
            checkLanguages(settings),
            checkCleanup(settings),
        ]
    }

    /// The checks that stop parrot working at all — what the Permissions pane
    /// lists, and what `doctor` treats as a setup problem rather than advice.
    /// One definition, so the pane and the CLI can't drift apart.
    static let requiredKinds: Set<CheckKind> = [.microphone, .accessibility, .fnKey]

    // MARK: - Checks

    static func checkMicrophone() -> Check {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return Check(kind: .microphone, name: "Microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                kind: .microphone,
                name: "Microphone",
                status: .warn("not requested yet"),
                remediation: "parrot records only while you hold the hotkey."
            )
        case .denied, .restricted:
            return Check(
                kind: .microphone,
                name: "Microphone",
                status: .fail("denied"),
                remediation: "macOS won't ask again once denied — turn it back on in System Settings."
            )
        @unknown default:
            return Check(
                kind: .microphone, name: "Microphone",
                status: .fail("unknown state"), remediation: nil
            )
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(kind: .accessibility, name: "Accessibility", status: .ok, remediation: nil)
        }
        return Check(
            kind: .accessibility,
            name: "Accessibility",
            status: .fail("not granted"),
            remediation: accessibilityRemediation()
        )
    }

    /// macOS grants Accessibility to an *application* or a standalone binary —
    /// never to the shell in between. Naming the immediate parent process would
    /// send the user hunting for "zsh" in a list that will never contain it.
    private static func accessibilityRemediation() -> String {
        let parent = parentProcessName()

        // Started by launchd: the daemon binary itself is the TCC subject.
        if getppid() == 1 || parent == "launchd" {
            return "Enable parrot in the Accessibility list. Already there? "
                + "The grant is tied to the binary's contents, so a rebuilt parrot "
                + "needs it toggled off and back on."
        }

        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"]
        if let parent, !shells.contains(parent) {
            return "Enable \(parent) in the Accessibility list."
        }

        return "Enable the terminal app you ran parrot from (Terminal, iTerm, Ghostty…), "
            + "not the shell. Or run `parrot start` and grant parrot itself."
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source /
    /// Show Emoji / Start Dictation. We need "Do Nothing" so Fn is a clean
    /// modifier — but only when Fn is actually the configured hotkey.
    static func checkFnKeyMapping(_ settings: Settings) -> Check {
        guard settings.hotkey == .fn else {
            return Check(kind: .fnKey, name: "Fn key", status: .ok, remediation: nil)
        }
        return checkFnKeyMapping()
    }

    static func checkFnKeyMapping() -> Check {
        let name = "Fn key"
        let fix = "Set “Press 🌐 key to” to “Do Nothing” so Fn stays a plain modifier."
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                kind: .fnKey, name: name,
                status: .warn("unset — the system default may intercept Fn"), remediation: fix
            )
        }
        switch value {
        case 0:
            return Check(kind: .fnKey, name: name, status: .ok, remediation: nil)
        case 1:
            return Check(kind: .fnKey, name: name, status: .fail("set to Change Input Source"), remediation: fix)
        case 2:
            return Check(kind: .fnKey, name: name, status: .fail("set to Show Emoji & Symbols"), remediation: fix)
        case 3:
            return Check(kind: .fnKey, name: name, status: .fail("set to Start Dictation"), remediation: fix)
        default:
            return Check(kind: .fnKey, name: name, status: .warn("unknown value \(value)"), remediation: fix)
        }
    }

    /// A model that isn't on disk isn't an error — it's a download waiting to
    /// happen, and the Models pane is where that happens.
    static func checkModel(_ settings: Settings) -> Check {
        let model = settings.resolvedModel
        // A cloud model has nothing to download; what it can be missing is a
        // key, and unlike cleanup there is no raw transcript to fall back to.
        if !model.isLocal, let account = model.engine.keychainAccount {
            return checkAPIKey(account, kind: .model, name: "Model")
        }
        guard model.isDownloaded else {
            return Check(
                kind: .model,
                name: "Model",
                status: .warn("\(model.id) isn't downloaded"),
                remediation: "Download it from the Models tab (\(model.sizeMB) MB)."
            )
        }
        return Check(kind: .model, name: "Model", status: .ok, remediation: model.id)
    }

    /// Validates `languages` and spells out what it will actually do — the
    /// setting reads like "only recognise these languages", but it only
    /// constrains the alphabet. Saying so here beats a surprise later.
    static func checkLanguages(_ settings: Settings) -> Check {
        let name = "Languages"
        guard !settings.languages.isEmpty else {
            return Check(kind: .languages, name: name, status: .ok, remediation: nil)
        }
        let listed = settings.languages.joined(separator: ", ")

        // Everything below describes Parakeet's script filter, which is the
        // most this setting can mean locally. The API takes the list as a real
        // multi-language hint, so none of those caveats apply.
        guard settings.resolvedModel.isLocal else {
            return Check(
                kind: .languages, name: name, status: .ok,
                remediation: "\(listed) — sent as language hints"
            )
        }

        switch LanguageSelection.resolve(settings.languages) {
        case .filter(let language):
            let script = LanguageSelection.describe(language.script)
            return Check(
                kind: .languages, name: name, status: .ok,
                remediation: "\(listed) — output restricted to the \(script) alphabet"
            )
        case .unrestricted:
            return Check(kind: .languages, name: name, status: .ok, remediation: nil)
        case .conflicting(let scripts):
            return Check(
                kind: .languages, name: name,
                status: .warn("\(listed) span \(scripts.joined(separator: " + ")) alphabets"),
                remediation: "No filtering is possible across alphabets — list languages sharing one."
            )
        case .unknownCodes(let bad):
            return Check(
                kind: .languages, name: name,
                status: .fail("unknown code(s): \(bad.joined(separator: ", "))"),
                remediation: "Supported: \(LanguageSelection.supportedCodes.joined(separator: " "))"
            )
        }
    }

    /// Cleanup is opt-in, so "off" is a pass. When it's on, verify the chosen
    /// provider can actually run here — otherwise the user finds out mid-dictation.
    static func checkCleanup(_ settings: Settings) -> Check {
        let name = "Cleanup"
        guard settings.cleanup.enabled else {
            return Check(kind: .cleanup, name: name, status: .ok, remediation: nil)
        }
        switch settings.cleanup.provider {
        case .apple:
            guard let reason = AppleCleanupAvailability.unavailableReason else {
                return Check(kind: .cleanup, name: name, status: .ok, remediation: nil)
            }
            return Check(
                kind: .cleanup, name: name, status: .warn(reason),
                remediation: "Switch to Anthropic or OpenAI, or turn cleanup off."
            )
        case .anthropic:
            return checkAPIKey(.anthropic)
        case .openai:
            return checkAPIKey(.openai)
        }
    }

    private static func checkAPIKey(
        _ account: Keychain.Account,
        kind: CheckKind = .cleanup,
        name: String = "Cleanup"
    ) -> Check {
        guard Keychain.apiKey(for: account) != nil else {
            return Check(
                kind: kind, name: name,
                status: .warn("no \(account.displayName) API key"),
                remediation: "Add one in the Accounts tab, or set \(account.envVar)."
            )
        }
        return Check(kind: kind, name: name, status: .ok, remediation: nil)
    }

    // MARK: - Helpers

    private static func readDefault(domain: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return (s as NSString).lastPathComponent
    }

    // MARK: - Terminal output

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name.lowercased()): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

}

/// The side of setup that *does* something, as opposed to reporting on it.
///
/// Only microphone access can actually be granted from inside the app. The
/// other two are System Settings panes the user has to visit, so the honest
/// button is one that takes them straight there rather than one that pretends
/// to fix it.
enum PermissionActions {
    /// Triggers the system prompt. Returns false if it was already decided —
    /// macOS never re-prompts once denied.
    @discardableResult
    static func requestMicrophone() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openMicrophoneSettings()
            return false
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the standard "grant Accessibility" alert, which also puts parrot
    /// in the list so there is something to toggle when the pane opens.
    static func promptAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openAccessibilitySettings()
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// The pane only exists on systems that have Apple Intelligence at all;
    /// `NSWorkspace.open` failing is the honest outcome elsewhere.
    static func openAppleIntelligenceSettings() {
        open("x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
