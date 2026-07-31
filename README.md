# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/enemyrr/parrot/master/scripts/install.sh | sh
parrot setup    # grants mic + accessibility, downloads the model
parrot start    # run in the background, now and at every login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot start` (background daemon, lives in the menu bar, comes back at login), or `parrot` in any terminal tab to watch it work.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Talk.** Two ways:
   - **Hold `fn`** — push-to-talk. Release when you're done.
   - **Double-tap `fn`** — hands-free. Recording stays on; tap once more to stop.
4. **The transcript types itself in at the cursor.** A small pill at the bottom of the screen shows the mic is hot; in hands-free mode it also shows a lock.

Press **Escape** while recording to throw the capture away.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## Config

Everything below is optional — parrot works with no config file at all.

```sh
parrot config init    # write a commented default to ~/.config/parrot/config.toml
parrot config path    # print where that file lives
```

```toml
model  = "parakeet-v3"   # `parrot models list` for options
hotkey = "fn"            # fn | option | control | command | shift

[hotkey_latch]
enabled     = true
tap_ms      = 300   # a hold shorter than this counts as a tap
window_ms   = 300   # the second tap must land within this
max_seconds = 300   # hands-free recordings stop themselves after this

[wordlist]
# Terms the cleanup model is told to preserve exactly as written.
vocabulary = ["Vercel", "FluidAudio"]

# Literal find -> replace on every transcript. Case-insensitive,
# word-boundary anchored, multi-word keys allowed.
[wordlist.replacements]
"claude code" = "Claude Code"
"vercell"     = "Vercel"

[history]
enabled     = true
max_entries = 5000
```

A config file that exists but doesn't parse is a hard error rather than a silent fallback — a typo'd wordlist should be loud.

## Cleanup (optional)

An opt-in pass that fixes punctuation, capitalization, and sentence breaks, and drops filler words. Off by default.

```toml
[cleanup]
enabled   = true
provider  = "apple"      # "apple" runs on-device; "anthropic" calls the API
min_words = 4            # skip cleanup below this — not worth the latency
timeout_s = 3.0
```

`provider = "apple"` uses Apple's on-device model (macOS 26+) — no key, no network, nothing leaves the machine. `provider = "anthropic"` calls Claude Haiku; store the key with `parrot cleanup set-key` (it goes in the Keychain, never in the config file).

If cleanup fails, times out, or returns something implausible, parrot injects the raw transcript instead. **Dictation never blocks on a language model.**

## History

Every transcript is logged to `~/.local/share/parrot/history.jsonl` (mode `0600`), with both the raw and the final text. The last 10 are in the menu bar — click one to copy it.

```sh
parrot history                  # last 20
parrot history -n 50            # last 50
parrot history search vercel    # case-insensitive substring search
parrot history clear            # delete everything
```

Set `history.enabled = false` to record nothing. Worth knowing: this captures everything you dictate, including anything you accidentally dictate into a password field.

## Running it in the background

```sh
parrot start        # run now and at every login
parrot status       # is it alive? which binary, model, hotkey, last transcript
parrot restart      # pick up a rebuilt binary
parrot logs -f      # follow the daemon's log
parrot stop         # stop and unregister
```

`start` reports whether the daemon actually came up, rather than just claiming success — if it can't register the hotkey, it says so and tells you what to fix.

**Accessibility is tied to the binary's contents**, so a rebuilt parrot needs re-approving in System Settings → Privacy & Security → Accessibility (toggle it off and back on if it's already listed). When permission is missing the daemon exits cleanly instead of crash-looping, so you get one prompt rather than one every ten seconds.

Working on parrot itself? Point the daemon at a dev build and skip `sudo` entirely:

```sh
parrot start --binary "$(swift build -c release --show-bin-path)/parrot"
# then, after each rebuild:
parrot restart
```

Logs live in `~/Library/Logs/parrot/`.

## CLI

```sh
parrot                           # run in the foreground (^C to quit)
parrot setup                     # one-time setup: permissions + model download
parrot start | stop | restart    # background daemon control
parrot status | logs             # is it running, and what has it been doing
parrot doctor                    # check permissions, fn key, config, cleanup
parrot models list               # list available models
parrot models download <id>      # pre-download a model
parrot config init | path        # create / locate the config file
parrot history [search|clear]    # browse past transcriptions
parrot cleanup set-key           # store an Anthropic API key in the Keychain
parrot --model parakeet-v2       # English-only model, slightly better English WER
parrot --hotkey option           # change the push-to-talk key
parrot --no-overlay              # disable the bottom-of-screen pill
```

`parrot install --launch-at-login` / `--uninstall` still work as aliases for `start` / `stop`.

## Models

| id | languages | notes |
|---|---|---|
| `parakeet-v3` | 25 European (auto-detect) | default |
| `parakeet-v2` | English only | ~0.3pp better English WER |

Both are NVIDIA Parakeet TDT 0.6B, running on the Neural Engine via FluidAudio. Unlike Whisper, a transducer emits nothing for silence — a short noisy tap of the hotkey produces an empty transcript rather than an invented `[BLANK_AUDIO]`.

## Stack

- **Swift** — single SPM executable target
- **FluidAudio** — Parakeet TDT inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill
- **FoundationModels** — optional on-device transcript cleanup (macOS 26+)

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
