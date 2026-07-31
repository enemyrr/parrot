import CoreGraphics
import Foundation

/// The key you hold to dictate.
///
/// Two shapes, because push-to-talk has two natural gestures:
///
/// - **A bare modifier** (`keyCode == nil`). Hold Fn, or Option, and talk.
///   Nothing is typed while you hold it, which is why this is the default.
/// - **A key with modifiers** — ⌃⌥Space, F13. Needed by anyone whose Fn or
///   Option is already spoken for, and the shape every other shortcut on the
///   Mac has.
///
/// A bare *key* is deliberately not representable. The event tap is listen-only
/// on purpose — parrot watches the keyboard, it never swallows from it — so
/// holding a plain letter would type a screenful of it into whatever is in
/// front. Anything without a modifier has to be a function key, which produces
/// no character to begin with.
struct Hotkey: Codable, Equatable, Hashable {
    /// Virtual keycode, or nil when the modifier itself is the hotkey.
    var keyCode: UInt16?
    var modifiers: HotkeyModifiers
    /// What to print for `keyCode`, captured when the shortcut was recorded.
    /// Storing it beats translating a keycode back through the current input
    /// source at display time — that needs `UCKeyTranslate`, and it would
    /// relabel someone's shortcut when they switched keyboard layouts.
    var keyLabel: String?

    // MARK: - Presets

    static let fn = Hotkey(modifiers: .fn)
    static let option = Hotkey(modifiers: .option)
    static let control = Hotkey(modifiers: .control)
    static let command = Hotkey(modifiers: .command)
    static let shift = Hotkey(modifiers: .shift)

    /// The one-tap choices offered above the recorder.
    static let presets: [Hotkey] = [.fn, .option, .control, .command, .shift]

    init(keyCode: UInt16? = nil, modifiers: HotkeyModifiers, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// True when the hotkey is a modifier held on its own.
    var isBareModifier: Bool { keyCode == nil }

    var isPreset: Bool { Self.presets.contains(self) }

    // MARK: - Display

    /// What goes on the keycap: "🌐", "⌥", "⌃⌥Space".
    var displayLabel: String {
        guard let keyLabel else {
            return modifiers.symbols.isEmpty ? "?" : modifiers.symbols
        }
        return modifiers.symbols + keyLabel
    }

    /// What goes in a sentence: "Fn", "Option", "⌃⌥Space".
    var displayName: String {
        guard isBareModifier else { return displayLabel }
        return modifiers.singleName ?? displayLabel
    }

    /// Whether this can actually be used. A bare modifier needs to be exactly
    /// one; a key needs a modifier unless it types nothing on its own.
    var isUsable: Bool {
        guard let keyCode else { return modifiers.isSingle }
        return !modifiers.isEmpty || KeyNames.isFunctionKey(keyCode)
    }

    // MARK: - Codable

    /// Also accepts the plain string a much earlier build wrote ("fn"), so a
    /// settings blob from one doesn't reset the hotkey to the default.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let name = try? single.decode(String.self),
           let preset = Self.preset(named: name) {
            self = preset
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifiers = try c.decodeIfPresent(HotkeyModifiers.self, forKey: .modifiers) ?? []
        keyLabel = try c.decodeIfPresent(String.self, forKey: .keyLabel)
    }

    /// The spellings the retired `config.toml` accepted.
    static func preset(named name: String) -> Hotkey? {
        switch name.lowercased() {
        case "fn", "function", "globe": return .fn
        case "option", "alt", "left-option", "right-option": return .option
        case "control", "ctrl": return .control
        case "command", "cmd": return .command
        case "shift": return .shift
        default: return nil
        }
    }
}

/// The modifier set, as one value.
///
/// `CGEventFlags` carries no left/right distinction, so "option" means either
/// option key. Telling them apart would mean tracking keycodes through
/// `flagsChanged`, which isn't worth it for a hold-to-talk key.
struct HotkeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let fn = HotkeyModifiers(rawValue: 1 << 0)
    static let control = HotkeyModifiers(rawValue: 1 << 1)
    static let option = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)
    static let command = HotkeyModifiers(rawValue: 1 << 4)

    /// Apple's printed order for a shortcut: fn ⌃ ⌥ ⇧ ⌘.
    static let ordered: [(HotkeyModifiers, String, String)] = [
        (.fn, "🌐", "Fn"),
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    var isSingle: Bool { rawValue != 0 && rawValue & (rawValue - 1) == 0 }

    var symbols: String {
        Self.ordered.filter { contains($0.0) }.map(\.1).joined()
    }

    /// The written name, but only when this is exactly one modifier.
    var singleName: String? {
        guard isSingle else { return nil }
        return Self.ordered.first { contains($0.0) }?.2
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.fn) { flags.insert(.maskSecondaryFn) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Only the five we care about — `CGEventFlags` also carries caps lock,
    /// the numeric-keypad bit and a device-dependent field, none of which
    /// should make a shortcut stop matching.
    init(cgFlags: CGEventFlags) {
        var set: HotkeyModifiers = []
        if cgFlags.contains(.maskSecondaryFn) { set.insert(.fn) }
        if cgFlags.contains(.maskControl) { set.insert(.control) }
        if cgFlags.contains(.maskAlternate) { set.insert(.option) }
        if cgFlags.contains(.maskShift) { set.insert(.shift) }
        if cgFlags.contains(.maskCommand) { set.insert(.command) }
        self = set
    }
}

/// Names for the keys that don't print a character of their own.
enum KeyNames {
    static let escape: UInt16 = 53

    private static let special: [UInt16: String] = [
        49: "Space",
        36: "Return",
        76: "Enter",
        48: "Tab",
        51: "Delete",
        117: "Fwd Del",
        53: "Esc",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
        115: "Home",
        119: "End",
        116: "Page Up",
        121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// A printable character wins; otherwise the table; otherwise the raw code,
    /// which at least tells the user their shortcut is distinct from another.
    static func label(keyCode: UInt16, characters: String?) -> String {
        if let special = special[keyCode] { return special }
        if let characters, !characters.isEmpty,
           !characters.unicodeScalars.allSatisfy({ $0.properties.isDefaultIgnorableCodePoint })
        {
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.uppercased() }
        }
        return "Key \(keyCode)"
    }
}
