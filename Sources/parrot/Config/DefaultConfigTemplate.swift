import Foundation

/// The commented starter file `parrot config init` writes. Kept in source so
/// the binary has no resource bundle to ship alongside it.
enum DefaultConfigTemplate {
    static let contents = """
    # parrot configuration — https://github.com/enemyrr/parrot
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
    # machine. "anthropic" and "openai" call the respective API — store the
    # key in the Keychain with `parrot cleanup set-key <provider>`.
    [cleanup]
    enabled   = false
    provider  = "apple"   # "apple" | "anthropic" | "openai"
    # Empty = the provider's default (claude-haiku-4-5 / gpt-5-mini).
    model     = ""
    # OpenAI reasoning models only: "minimal" | "low" | "medium" | "high".
    # Empty omits the parameter. Anything above "minimal" trades latency for
    # quality — mind timeout_s.
    reasoning_effort = ""
    min_words = 4         # skip cleanup below this
    timeout_s = 3.0
    prompt    = ""        # empty = built-in prompt

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

    # Usage totals — counts only, never the text you dictated, so this can stay
    # on with history off. Kept in its own file that `parrot history clear`
    # doesn't touch. `parrot stats` to see them.
    [stats]
    enabled = true
    # Assumed typing speed, used only to work out "time saved". 40 wpm is
    # composing-original-text speed, which is well below what a typing test
    # measures. `parrot stats` shows the assumption next to the number.
    typing_wpm = 40

    [overlay]
    # How the recording pill visualises your voice:
    #   "bars"  scrolling meter, newest sample enters right and travels left
    #   "line"  Siri-style wave, flat when silent
    style = "bars"
    # Meter sensitivity, 0.25–3.0. Higher lowers the noise floor, so a quiet
    # mic or a soft voice still fills the bars. Tune it live with
    # `parrot overlay-preview` (+/- keys).
    sensitivity = 1.0

    """
}
