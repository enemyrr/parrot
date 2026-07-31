import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    /// `config` is nil when the file failed to parse — that's itself a finding.
    static func run(config: Config?) -> [Check] {
        [
            checkMicrophone(),
            checkAccessibility(),
            checkFnKeyMapping(),
            checkConfig(config),
            checkLanguages(config),
            checkCleanup(config),
        ]
    }

    /// Validates `languages` and spells out what it will actually do — the
    /// setting reads like "only recognise these languages", but it only
    /// constrains the alphabet. Saying so here beats a surprise later.
    static func checkLanguages(_ config: Config?) -> Check {
        guard let config, !config.languages.isEmpty else {
            return Check(name: "languages", status: .ok, remediation: nil)
        }
        let listed = config.languages.joined(separator: ", ")

        switch LanguageSelection.resolve(config.languages) {
        case .filter(let language):
            let script = LanguageSelection.describe(language.script)
            return Check(
                name: "languages",
                status: .ok,
                remediation: "\(listed) — output restricted to the \(script) alphabet"
            )
        case .unrestricted:
            return Check(name: "languages", status: .ok, remediation: nil)
        case .conflicting(let scripts):
            return Check(
                name: "languages",
                status: .warn("\(listed) span \(scripts.joined(separator: " + ")) alphabets"),
                remediation: "no filtering is possible across alphabets — list languages sharing one"
            )
        case .unknownCodes(let bad):
            return Check(
                name: "languages",
                status: .fail("unknown code(s): \(bad.joined(separator: ", "))"),
                remediation: "supported: \(LanguageSelection.supportedCodes.joined(separator: " "))"
            )
        }
    }

    static func checkConfig(_ config: Config?) -> Check {
        let path = ParrotPaths.configFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(name: "config", status: .ok, remediation: nil)
        }
        guard config != nil else {
            return Check(
                name: "config",
                status: .fail("could not parse \(path)"),
                remediation: "fix the TOML, or `parrot config init --force` to start over"
            )
        }
        return Check(name: "config", status: .ok, remediation: nil)
    }

    /// Cleanup is opt-in, so "off" is a pass. When it's on, verify the chosen
    /// provider can actually run here — otherwise the user finds out mid-dictation.
    static func checkCleanup(_ config: Config?) -> Check {
        guard let config, config.cleanup.enabled else {
            return Check(name: "cleanup", status: .ok, remediation: nil)
        }
        switch config.cleanup.provider {
        case .apple:
            if #available(macOS 26, *) {
                if let reason = AppleFoundationCleaner.unavailableReason {
                    return Check(
                        name: "cleanup",
                        status: .warn(reason),
                        remediation: "set provider = \"anthropic\" or \"openai\", or disable cleanup"
                    )
                }
                return Check(name: "cleanup", status: .ok, remediation: nil)
            }
            return Check(
                name: "cleanup",
                status: .warn("provider \"apple\" needs macOS 26 or later"),
                remediation: "set provider = \"anthropic\" or \"openai\", or disable cleanup"
            )
        case .anthropic:
            return checkAPIKey(.anthropic)
        case .openai:
            return checkAPIKey(.openai)
        }
    }

    private static func checkAPIKey(_ account: Keychain.Account) -> Check {
        guard Keychain.apiKey(for: account) != nil else {
            return Check(
                name: "cleanup",
                status: .warn("no \(account.displayName) API key"),
                remediation: "run `parrot cleanup set-key \(account.rawValue)`, "
                    + "or set \(account.envVar)"
            )
        }
        return Check(name: "cleanup", status: .ok, remediation: nil)
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run parrot and hold Fn once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: accessibilityRemediation()
        )
    }

    /// macOS grants Accessibility to an *application* or a standalone binary —
    /// never to the shell in between. Naming the immediate parent process would
    /// send the user hunting for "zsh" in a list that will never contain it.
    private static func accessibilityRemediation() -> String {
        let settings = "System Settings → Privacy & Security → Accessibility"
        let parent = parentProcessName()

        // Started by launchd: the daemon binary itself is the TCC subject.
        if getppid() == 1 || parent == "launchd" {
            return "\(settings) → enable parrot"
        }

        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"]
        if let parent, !shells.contains(parent) {
            return "\(settings) → enable \(parent)"
        }

        // Running from a shell — the grant lands on the terminal app hosting it,
        // which we can't reliably name from here.
        return """
            \(settings) → enable the terminal app you ran parrot from \
            (Terminal, iTerm, Ghostty, VS Code…), not the shell.
                Already listed? The grant is tied to the binary's contents, so \
            a rebuilt parrot needs it toggled off and back on.
                Or run `parrot install --launch-at-login` and grant parrot itself.
            """
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Change Input Source"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 2:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Show Emoji & Symbols"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 3:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Start Dictation"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

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
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
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

    /// True only if every check passed cleanly (used by `parrot doctor` exit code).
    static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}
