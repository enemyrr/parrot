import Foundation

/// The commented starter file `parrot config init` writes. Kept in source so
/// the binary has no resource bundle to ship alongside it.
enum DefaultConfigTemplate {
    static let contents = """
    # parrot configuration — https://github.com/digimata/parrot
    # Every value below is a default; delete a line to keep the default.

    model  = "parakeet-v3"   # `parrot models list` for options
    hotkey = "fn"            # fn | option | control | command | shift

    # Hold the hotkey to push-to-talk. Double-tap it for hands-free mode,
    # then tap once more to stop. Escape discards a recording in progress.
    [hotkey_latch]
    enabled     = true
    tap_ms      = 300   # a hold shorter than this counts as a tap
    window_ms   = 300   # the second tap must land within this
    max_seconds = 300   # hands-free recordings stop themselves after this

    # Optional pass over the transcript to fix punctuation and drop filler
    # words. "apple" runs on-device (requires macOS 26+) and never leaves the
    # machine. "anthropic" calls the API — set the key with
    # `parrot cleanup set-key`, which stores it in the Keychain.
    [cleanup]
    enabled   = false
    provider  = "apple"                     # "apple" | "anthropic"
    model     = "claude-haiku-4-5"          # anthropic only
    min_words = 4                           # skip cleanup below this
    timeout_s = 3.0
    prompt    = ""                          # empty = built-in prompt

    [wordlist]
    # Terms the cleanup model is told to preserve exactly as written.
    vocabulary = []

    # Literal find -> replace, applied to every transcript. Matching is
    # case-insensitive and word-boundary anchored; multi-word keys work.
    [wordlist.replacements]
    # "claude code" = "Claude Code"
    # "vercell"     = "Vercel"

    [history]
    enabled     = true
    max_entries = 5000

    """
}
