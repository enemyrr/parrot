import AppKit
import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Above this, typing is swapped for a paste.
    ///
    /// Synthesised keystrokes go in 20 characters at a time, so a 1500-character
    /// email is 75 events posted back-to-back — which Electron apps and web
    /// text areas visibly drop characters from. A dictated sentence is short
    /// enough that typing stays the better behaviour: it needs no clipboard, and
    /// it lands in apps where ⌘V is bound to something else.
    static let pasteThreshold = 200

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    /// Put text in the frontmost app, picking how by length.
    ///
    /// A selection, if there is one, is replaced by both paths — typing over a
    /// selection replaces it, and so does pasting over it. So "replace" needs
    /// no separate mechanism: it needs the selection left alone until this
    /// runs, which is why nothing here clicks or moves the cursor first.
    static func put(_ text: String) {
        guard !text.isEmpty else { return }
        if text.count < pasteThreshold {
            inject(text)
        } else {
            paste(text)
        }
    }

    /// Clipboard round-trip, with the user's own clipboard put back.
    ///
    /// Restoring is best-effort and deliberately delayed: the paste is
    /// asynchronous — the keystroke only tells the frontmost app to read the
    /// pasteboard — so putting the old contents back immediately races the app
    /// that is about to read it.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Only plain string contents are preserved. Restoring an arbitrary
        // pasteboard means copying every representation of every item, and
        // getting that wrong silently corrupts what someone had copied.
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // If something else has taken the pasteboard since, leave it alone:
            // putting our copy back would undo whatever the user just copied.
            guard pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    private static let vKeyCode: CGKeyCode = 9

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Suppress the local keyboard state so a modifier the user is still
        // holding — the squawk key itself, in the moment after a hands-free
        // stop — doesn't turn ⌘V into ⌃⌘V.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
