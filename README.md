# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/enemyrr/parrot/master/scripts/install.sh | sh
parrot start    # run in the background, now and at every login
```

On first launch parrot opens its settings window, downloads the model with a progress bar, and walks you through the two permissions macOS needs. Nothing to configure by hand.

Or grab `parrot.dmg` from [Releases](https://github.com/enemyrr/parrot/releases) and drag it to Applications — signed and notarized, so it just opens.

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The script install drops the binary in `/usr/local/bin/parrot`. The `.app` bundles the same binary at `parrot.app/Contents/MacOS/parrot`, so every CLI command works either way.

## Build the app bundle

```sh
./scripts/bundle.sh              # ad-hoc signed, for local testing
./scripts/bundle.sh --notarize   # Developer ID + notarize + staple
```

Produces `dist/parrot.app` and a drag-to-install `dist/parrot-<version>.dmg` — styled window, app on the left, Applications on the right, arrow between them.

Both the app icon and the DMG background are rendered at build time from the same bird glyph the menu bar uses (`scripts/make-icon.swift`, `scripts/make-dmg-background.swift`), so there's no binary asset in the repo. Drop a real `.icns` in later to replace it.

Signing picks up a "Developer ID Application" cert automatically; set `SIGN_IDENTITY` to pin a specific one. Notarizing needs credentials stored once:

```sh
xcrun notarytool store-credentials parrot \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Only a notarized build opens on someone else's Mac without Gatekeeper blocking it. The app icon is generated from the same bird glyph as the menu bar (`scripts/make-icon.swift`), so there's no binary asset in the repo.

## How to use

1. **Run it.** Either `parrot start` (background daemon, lives in the menu bar, comes back at login), or `parrot` in any terminal tab to watch it work.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Talk.** Two ways:
   - **Hold `fn`** — push-to-talk. Release when you're done.
   - **Double-tap `fn`** — hands-free. Recording stays on; tap once more to stop.
4. **The transcript types itself in at the cursor.** A small pill at the bottom of the screen shows the mic is hot; in hands-free mode it also shows a lock.

Press **Escape** while recording to throw the capture away. If you press an
ordinary shortcut while holding a bare modifier — `⌃C` while `⌃` is your squawk
key — the recording is thrown away too, so your shortcuts keep working.

## Squawk

Dictation types what you say. **Squawk answers for you.**

Hold **`⌃`** instead of `fn`, and what you say becomes an instruction rather
than text:

> *"answer this, say ten o'clock works"*
> *"rewrite this in a friendlier tone"*
> *"reply that we can't make the deadline, and offer the fifteenth"*

It reads the app you're in — the thread you're looking at, the draft you've
started, whatever you've selected — and writes the answer at your cursor. If you
had text selected, the answer replaces it; otherwise it goes in at the cursor.

The point is that **you** decide the substance. Other tools guess what you meant
and get it wrong the moment a question has two possible answers; here you say
which one, in three words, and it writes the rest.

The pill tells the two apart: dictation is a scrolling bar meter in cool blue,
squawk is a wave with a `✦` in warm amber.

Squawk is **off by default**. Turn it on in the **Keys** tab; pick the model in
the **Squawk** tab.

### What it can see

Only the app in front, and only when you're holding the key. In order:

1. Your selection, if there is one.
2. The field the cursor is in.
3. The readable text of the focused window, filtered and capped.

Password managers, the login window, and any secure text field are never read —
that isn't configurable. You can exclude any other app by bundle id.

To see exactly what would be sent, use the **Show me what you'd send** button in
the Squawk tab, or:

```sh
parrot context            # what squawk would read from the app in front
parrot context --app Mail # ...from a named app, without switching to it
parrot context --tree     # the raw accessibility tree, for tuning
```

Browsers and Electron apps (Chrome, Slack, VS Code, Discord) build an
accessibility tree only when asked. parrot asks — once per app, and never with
the flag that disturbs a field you're typing in. You can turn that off, at the
cost of those apps returning nothing.

### Telling it who you are

Three layers, all editable in the Squawk tab:

- **Base prompt** — the rules of the mode. What "rewrite this" means, what
  "answer this" means, that only the text comes back.
- **About you** — "I'm Andreas, I run a staffing company, I sign off with just
  my first name, I write Swedish with Swedish colleagues." Goes into every
  squawk.
- **Per-app instructions** — Mail gets a greeting and a sign-off; Messages gets
  one lowercase line; Slack gets a short paragraph. First match wins.

You can run one without talking, which is also how you tune a prompt:

```sh
parrot squawk --dry-run "answer this, ten o'clock works"
parrot squawk --show-prompt "rewrite this"     # the exact prompt that gets sent
```

### Models

Squawk and cleanup pick their models independently — cleanup wants something
fast that fixes punctuation, squawk wants something that can write.

| Provider | |
|---|---|
| **Apple** | On-device. The screen contents never leave the Mac. Weakest writer of the three, needs no key. The default. |
| **Anthropic** | Claude, over the API. Needs a key. |
| **OpenAI** | GPT, over the API. Needs a key. |

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," the Permissions tab will tell you how to flip it back to plain `fn`.

## Settings

Everything lives in one window — `parrot settings`, or **Settings…** in the menu bar (`⌘,`).

| Tab | What's in it |
|---|---|
| **General** | Spoken languages, start-at-login, where the log lives |
| **Keys** | Both hotkeys — dictation and squawk — and the hands-free timings |
| **Squawk** | The model behind squawk, what it knows about you, per-app instructions, what it may read |
| **Models** | Which model, download progress, size on disk, delete |
| **Cleanup** | Raw vs cleaned, provider, prompt |
| **Dictionary** | Vocabulary and find → replace rules |
| **Appearance** | The recording pill's look, with a live microphone preview |
| **Accounts** | API keys, and what is currently using each one |
| **History** | Recent transcripts, usage totals, retention |
| **Permissions** | Microphone, Accessibility and the Fn key mapping, re-checked live |

**Changes apply immediately** — no restart, no file to edit. Settings are stored in macOS preferences (`com.digimata.parrot`), API keys in the Keychain.

Upgrading from a version that used `~/.config/parrot/config.toml`? The first launch imports it and renames it to `config.toml.migrated`. Nothing is lost, and nothing reads it again.

### Push to talk

Pick a bare modifier — Fn, Option, Control, Command, Shift — and hold it. Or record any shortcut you like (⌃⌥Space, F13) with **Record shortcut**.

A recorded shortcut needs a modifier, or has to be a function key. parrot watches the keyboard but never intercepts it, so a bare letter would type itself across the screen while you talked.

### Cleanup

An opt-in second pass that fixes punctuation, capitalization and sentence breaks, and drops filler words. Off by default.

- **Apple** runs on-device (macOS 26+) — no key, no network, nothing leaves the machine.
- **Anthropic** and **OpenAI** call their APIs. Paste the key in the Accounts tab, or use `parrot key set`; either way it goes in the Keychain, never in a settings file. `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` work as a fallback.

If cleanup fails, times out, or returns something implausible, parrot injects the raw transcript instead. **Dictation never blocks on a language model.**

## History

Every transcript is logged to `~/.local/share/parrot/history.jsonl` (mode `0600`), with both the raw and the final text. The last 10 are in the menu bar — click one to copy it.

```sh
parrot history                  # last 20
parrot history -n 50            # last 50
parrot history search vercel    # case-insensitive substring search
parrot history clear            # delete everything
```

Turn **Keep a history** off in the History tab to record nothing. Worth knowing: this captures everything you dictate, including anything you accidentally dictate into a password field.

## Running it in the background

```sh
parrot start        # run now and at every login
parrot status       # is it alive? which binary, model, hotkey, last transcript
parrot restart      # pick up a rebuilt binary
parrot logs -f      # follow the daemon's log
parrot stop         # stop and unregister
```

`start` reports whether the daemon actually came up, rather than just claiming success — if it can't register the hotkey, it says so and tells you what to fix.

**Accessibility is tied to the binary's contents**, so a rebuilt parrot needs re-approving in System Settings → Privacy & Security → Accessibility (toggle it off and back on if it's already listed). When permission is missing parrot stays up, opens the Permissions tab, and starts listening the moment the grant lands — no restart, and no crash-loop re-prompting you every ten seconds.

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
parrot settings                  # open the settings window
parrot settings --pane models    # …on a particular tab
parrot setup                     # alias for `settings --pane permissions`
parrot start | stop | restart    # background daemon control
parrot status | logs             # is it running, and what has it been doing
parrot doctor                    # the Permissions tab, as terminal output
parrot models list               # list models, and which are downloaded
parrot models download <id>      # pre-download a model
parrot history [search|clear]    # browse past transcriptions
parrot stats                     # how much you've dictated
parrot key set | clear <p>       # store or remove a provider API key
parrot key list                  # which providers have a key (never prints one)
parrot --no-overlay              # disable the bottom-of-screen pill for this run
parrot --dump-wav                # write each capture to /tmp/parrot-last.wav
```

`parrot doctor` is the one worth keeping in the terminal — it works over ssh, where a settings window doesn't.

`parrot install --launch-at-login` / `--uninstall` still work as aliases for `start` / `stop`.

## Models

| id | languages | where it runs | notes |
|---|---|---|---|
| `parakeet-v3` | 25 European (auto-detect) | this Mac | default |
| `parakeet-v2` | English only | this Mac | ~0.3pp better English WER |
| `gpt-transcribe` | 100+ | OpenAI | $0.0045/min, needs a key |

Both Parakeets are NVIDIA Parakeet TDT 0.6B, running on the Neural Engine via FluidAudio. Unlike Whisper, a transducer emits nothing for silence — a short noisy tap of the hotkey produces an empty transcript rather than an invented `[BLANK_AUDIO]`.

`gpt-transcribe` is the escape hatch, not an upgrade. It is **slower** — a network round trip against a fraction of a second on the ANE — it costs money, it needs a connection, and **your audio leaves the machine**. What it buys is the two things a local transducer structurally can't do:

- **Languages outside Parakeet's 25.** Japanese, Korean, Arabic, Hindi, Thai and the rest.
- **Steering.** Your Dictionary vocabulary is sent as `keywords`, and your spoken languages as `languages`, so they condition the decode instead of patching its output afterwards. That's the difference between the model hearing "Vercel" and a find/replace fixing "vercell" after the fact.

Pick it in the Models tab; the key lives in Accounts.

## Stack

- **Swift** — single SPM executable target
- **FluidAudio** — Parakeet TDT inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill
- **SwiftUI** — the settings window
- **FoundationModels** — optional on-device transcript cleanup (macOS 26+)

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
