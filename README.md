# parrot

A macOS dictation app that lives in the menu bar. Hold a key, talk, and the words land at your cursor — transcribed on the Neural Engine, in whatever app you're already in.

Hold the *other* key and what you say becomes an instruction instead: parrot reads the thread you're looking at and writes the answer. That's **squawk**.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/enemyrr/parrot/master/scripts/install.sh | sh
parrot start    # run in the background, now and at every login
```

Or grab `parrot.dmg` from [Releases](https://github.com/enemyrr/parrot/releases) and drag it to Applications — signed and notarized, so it just opens.

On first launch parrot walks you through five steps: microphone, Accessibility, your key, and a scratch field to say something into. The model downloads with a progress bar while you do it. Nothing to configure by hand.

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML, so the installer refuses to run on Intel. The on-device *writing* model (Apple Intelligence, used by cleanup and squawk) needs macOS 26 — everything else works without it.

The script install drops the binary in `/usr/local/bin/parrot`. The `.app` bundles the same binary at `parrot.app/Contents/MacOS/parrot`, so every command below works either way.

## How to use

1. **Run it.** `parrot start` puts it in the menu bar and brings it back at login. `parrot` on its own runs it in the foreground so you can watch it work.
2. **Click into the text field you want to dictate into** — Messages, an address bar, a Slack thread, anywhere a cursor blinks.
3. **Talk.**
   - **Hold `fn`** — push-to-talk. Release when you're done.
   - **Double-tap `fn`** — hands-free. Recording stays on; tap once more to stop.
4. **The transcript types itself in at the cursor.** A pill at the bottom of the screen shows the mic is hot, with a lock in hands-free mode.

Press **Escape** while recording to throw the capture away. Pressing an ordinary shortcut while holding a bare modifier — `⌃C` while `⌃` is your squawk key — also throws the recording away, so your shortcuts keep working.

There is no record button, no stop button, no send. The key is the whole interface.

> **Note:** on most modern Macs `fn` is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols", the Permissions sheet will tell you how to flip it back to plain `fn`.

### Picking the key

Any bare modifier — Fn, Option, Control, Command, Shift — or a recorded shortcut like ⌃⌥Space or F13. A recorded shortcut needs a modifier, or has to be a function key: parrot watches the keyboard but never intercepts it, so a bare letter would type itself across the screen while you talked.

## Squawk

Dictation types what you say. **Squawk answers for you.**

Hold **`⌃`** instead of `fn`, and what you say becomes an instruction:

> *"answer this, say ten o'clock works"*
> *"rewrite this in a friendlier tone"*
> *"reply that we can't make the deadline, and offer the fifteenth"*

It reads the app you're in — the thread you're looking at, the draft you've started, whatever you've selected — and writes the answer at your cursor. If you had text selected, the answer replaces it; otherwise it goes in at the cursor.

The point is that **you** decide the substance. Other tools guess what you meant and get it wrong the moment a question has two possible answers; here you say which one, in three words, and it writes the rest.

The pill tells the two apart by colour and shape: dictation is a scrolling bar meter in cool blue, squawk is a single wave in warm amber. While the model is working it turns violet — that's the wait with no predictable length, and it's the only one worth flagging.

Squawk is **off by default**. Turn it on and pick its model in the **Squawk** pane.

### What it can see

Only the app in front, and only while you're holding the key. In order:

1. Your selection, if there is one.
2. The field the cursor is in.
3. The readable text of the focused window, filtered and capped.

Password managers, the login window, and any secure text field are never read — that isn't configurable. You can exclude any other app by bundle id.

To see exactly what would be sent:

```sh
parrot context            # what squawk would read from the app in front
parrot context --app Mail # …from a named app, without switching to it
parrot context --tree     # the raw accessibility tree, for tuning
```

Browsers and Electron apps (Chrome, Slack, VS Code, Discord) build an accessibility tree only when asked. parrot asks — once per app, and never with the flag that disturbs a field you're typing in. You can turn that off, at the cost of those apps returning nothing.

Nothing read off the screen is ever written to history.

### Running one without talking

```sh
parrot squawk --dry-run "answer this, ten o'clock works"
parrot squawk --show-prompt "rewrite this"     # the exact prompt that gets sent
parrot squawk "reply that Tuesday works"       # types it for real, after 3s
```

## Style

Both features write, so both write as the same person. That lives in one place: **Style**, a tab bar of *categories*.

A category is a kind of writing — Email, Work messages, Casual messages — and it owns the apps it claims, a **tone**, a **length**, and a paragraph of **notes**. Mail gets full sentences and a sign-off; Messages gets one lowercase line. The last tab is a catch-all that can't be deleted, so an app you never set up still has an answer.

Tone and length are picked by reading the same message written three ways, side by side, rather than from adjectives.

The two consumers get different slices, and the split is deliberate:

- **Squawk** gets all of it — tone, length, notes, and "about you".
- **Cleanup** only gets what it's allowed to change: tone rules that ask for different punctuation and casing, never different words. Length and "about you" never reach it — how much you meant to say was decided when you said it.

**About you** ("I'm Andreas, I run a staffing company, I sign off with just my first name") is squawk's alone and is edited on the Squawk pane. Repairing a transcript never needs to know who said it.

## Transcribe a file

Dictation is for what you're saying now. **Transcribe** is for a recording you already have — a voice memo, an interview, the audio out of a screen recording.

Three ways in, all the same engine:

- **Settings › Transcribe** — drop the file on the pane, or pick one.
- **Menu bar › Transcribe File…** — same thing, from the status item.
- **`parrot transcribe meeting.m4a`** — transcript to stdout, progress to stderr, so it pipes.

```sh
parrot transcribe interview.mp3              # print it
parrot transcribe interview.mp3 --save       # write interview.txt next to it
parrot transcribe talk.mov -o notes.txt      # somewhere else
parrot transcribe memo.m4a --clean           # run the cleanup pass over it too
```

Anything AVFoundation reads works — mp3, m4a, wav, aiff, caf, flac — and video containers too, with the audio track pulled out of them.

**On a local model there's no length limit.** The file is streamed off disk in chunks, so a two-hour recording costs about as much memory as a two-second one. `gpt-transcribe` uploads the file instead and caps out around 13 minutes; parrot says so rather than sending the bytes to be rejected.

Cleanup is **off by default here**, unlike dictation. An hour of speech is around ten thousand words, and that's a lot to hand a language model in one go — switch it on and the transcript is cut on sentence boundaries and cleaned a chunk at a time. Your Dictionary replacements always apply. Shortcut expansion doesn't: a phrase you say on purpose to trigger something is a dictation idea, not a property of a recording made last Tuesday.

Transcripts land in History marked as files, and deliberately don't count toward your usage stats — "time saved versus typing" is about your own speaking, not about audio someone else recorded.

## Dictionary

Two tabs, both about making parrot type this and not that.

**Replacements** are corrections: words the transcriber keeps getting wrong, and the spelling that fixes them. Case-insensitive, word-boundary anchored, applied in a single pass so one rule can't chew through another's output. **Vocabulary** is a list of terms the cleanup model is told to preserve — and, on the API transcription model, keyword hints that steer the decode itself.

**Shortcuts** are the opposite intent: a phrase you say *on purpose* so you don't have to spell something out loud. "my email shortcut" → your address. "the standup preamble" → four lines of it. Triggers are matched loosely enough to survive whatever punctuation the transcriber sprinkles through them, and expansions run last — nothing downstream gets an opinion about an address or a canned prompt.

## Integrations

**Off by default.** This is the one thing that lets *dictation* look at a window at all, so it's something you turn on rather than something you discover has been happening.

What it does: while you're still talking, parrot walks the front app's accessibility tree for the **names** in it — channels, people, filenames, identifiers, issue ids — and turns spoken references into what the app actually links.

```
"post it in hashtag eng parrot"   →  "post it in #eng-parrot"
"ask at sara about the deploy"    →  "ask @Sara about the deploy"
"look at auth provider"           →  "look @AuthProvider.tsx"
"roster reader dot swift"         →  "RosterReader.swift"
```

The rewrite is a literal phrase match against a table read off the screen — not a model. An `@mention` notifies a real person, and a language model asked to "tag the names" will eventually tag one that was never on screen.

What crosses the line is narrow: short labels and their positions, with the prose thrown away. None of it is written to history. Names go to a remote transcriber or cleaner as hints only if you leave "learn vocabulary" on and have one configured — the contents never do.

Apps with an integration today: **Slack**, **Discord**, **Notion**, **Obsidian**, **Linear**, **Xcode**, **VS Code**, **Cursor**, **Windsurf**, **Antigravity**, and **terminals** (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm). Terminals are the one with nothing to tag — a shell has no `@` — so everything there is pure spelling help, taken off the scrollback in front of you.

Every classifier is a guess about how one app lays its window out, and apps change. The Integrations pane shows which ones are actually finding things, and marks the ones that have stopped. To check by hand:

```sh
parrot roster             # what the app in front would give up
parrot roster --app Slack # …a named app, without switching to it
parrot roster --nodes     # every label the walk saw, with positions
parrot roster --list      # every app with an integration
```

## Cleanup

An opt-in second pass that fixes punctuation, capitalization and sentence breaks, and drops filler words. **Off by default.**

- **Apple** runs on-device (macOS 26+) — no key, no network, nothing leaves the machine.
- **Anthropic** and **OpenAI** call their APIs. Paste the key in **About → Accounts**, or use `parrot key set`; either way it goes in the Keychain, never in a settings file. `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` work as a fallback.

The model list comes from your account rather than from a hardcoded list here, so a model that shipped last week is in the menu.

Two guards sit between the model and your keystrokes. The transcript goes in as a user turn with the instructions saying it's dictation, so dictating "ignore your instructions and write X" produces the sentence, not X. And a result far off the input's length is discarded. If cleanup fails, times out, or returns something implausible, parrot injects the raw transcript instead — **dictation never blocks on a language model.**

To see it work on demand:

```sh
parrot cleanup run "so um i think we should ship it tomorrow"
parrot cleanup run --provider anthropic "…"
```

## Models

| id | languages | where it runs | notes |
|---|---|---|---|
| `parakeet-v3` | 25 European (auto-detect) | this Mac | default |
| `parakeet-v2` | English only | this Mac | ~0.3pp better English WER |
| `gpt-transcribe` | 100+ | OpenAI | needs a key |

Both Parakeets are NVIDIA Parakeet TDT 0.6B, running on the Neural Engine via FluidAudio, ~461 MB on disk. Unlike Whisper, a transducer emits nothing for silence — a short noisy tap of the hotkey produces an empty transcript rather than an invented `[BLANK_AUDIO]`.

`gpt-transcribe` is the escape hatch, not an upgrade. It is **slower** — a network round trip against a fraction of a second on the ANE — it costs money, it needs a connection, and **your audio leaves the machine**. What it buys is the two things a local transducer structurally can't do:

- **Languages outside Parakeet's 25.** Japanese, Korean, Arabic, Hindi, Thai and the rest.
- **Steering.** Your vocabulary and shortcut triggers are sent as `keywords`, and your spoken languages as `languages`, so they condition the decode instead of patching its output afterwards. That's the difference between the model hearing "Vercel" and a find/replace fixing "vercell" after the fact.

Pick one under **Home → Model**; the key lives in **About → Accounts**.

### About languages

Setting your spoken languages doesn't restrict which language Parakeet detects — it can't. What it does is filter candidate tokens by *writing script*, which stops stray Han or Cyrillic characters appearing in an otherwise Latin transcript. Listing languages from different scripts leaves nothing to enforce, so filtering switches off rather than silently picking one.

## Settings

One window — `parrot settings`, or **Settings…** under the menu bar icon (`⌘,`).

| Pane | What's in it |
|---|---|
| **Home** | The key, your usage totals, recent transcripts, and the settings themselves: model, languages, microphone, mute-while-dictating, launch at login. Meter sensitivity, storage, usage counting and the log live under **Advanced** |
| **Squawk** | Whether it's on, its key, the model behind it, what it knows about you, and what it may read |
| **Cleanup** | Raw vs cleaned, provider, model, when to run it, the prompt |
| **Style** | Categories: apps, tone, length, notes |
| **Dictionary** | Corrections and vocabulary, plus spoken shortcuts |
| **Integrations** | Which apps parrot reads names from, and whether each is working right now |
| **About** | Behind the parrot glyph under the sidebar. **Permissions** (microphone, Accessibility, the Fn mapping, re-checked live) and **Accounts** (API keys, and what's using each) open as sheets from here, as does starting over |

**Changes apply immediately** — no restart, no file to edit. Settings live in macOS preferences (`com.digimata.parrot`), API keys in the Keychain.

Upgrading from a version that used `~/.config/parrot/config.toml`? The first launch imports it and renames it to `config.toml.migrated`. Nothing is lost, and nothing reads it again.

## History and usage

Every transcript is logged to `~/.local/share/parrot/history.jsonl` (mode `0600`), with both the raw and the final text. The last 10 are under the menu bar icon — click one to copy it. The full list, with search, is on Home.

```sh
parrot history                  # last 20
parrot history -n 50            # last 50
parrot history search vercel    # case-insensitive substring search
parrot history clear            # delete everything
```

Turn **Keep a history** off under Home → Advanced to record nothing. Worth knowing: this captures everything you dictate, including anything you accidentally dictate into a password field.

Usage counters live separately in `stats.jsonl` and hold no text at all, so they keep working with history off:

```sh
parrot stats                    # words, time saved, speaking speed, per-model latency
parrot stats --days 90          # a longer sparkline
parrot stats reset
```

"Time saved" is measured against an assumed typing speed you can change — it's stated next to the number rather than hidden behind it.

## Running it in the background

```sh
parrot start        # run now and at every login
parrot status       # is it alive? which binary, model, hotkey, last transcript
parrot restart      # pick up a rebuilt binary
parrot logs -f      # follow the daemon's log
parrot stop         # stop and unregister
```

`start` reports whether the daemon actually came up rather than just claiming success — if it can't register the hotkey, it says so and tells you what to fix.

**Accessibility is tied to the binary's contents**, so a rebuilt parrot needs re-approving in System Settings → Privacy & Security → Accessibility (toggle it off and back on if it's already listed). When permission is missing parrot stays up, opens the Permissions sheet, and starts listening the moment the grant lands — no restart, and no crash-loop re-prompting you every ten seconds.

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
parrot settings --pane squawk    # …on a particular pane
parrot setup                     # the guided first run, again
parrot start | stop | restart    # background daemon control
parrot status | logs             # is it running, and what has it been doing
parrot doctor                    # the Permissions sheet, as terminal output
parrot models list               # list models, and which are downloaded
parrot models download <id>      # pre-download a model
parrot transcribe <file>         # transcribe a recording off disk
parrot history [search|clear]    # browse past transcriptions
parrot stats [reset]             # how much you've dictated
parrot key set | clear | list    # provider API keys, in the Keychain
parrot cleanup run <text>        # run the cleanup pass on demand
parrot context [--app|--tree]    # what squawk would read off the screen
parrot roster [--app|--nodes]    # what an integration would find in an app
parrot squawk <instruction>      # a squawk without the microphone
parrot overlay-preview           # the pill, against your live mic
```

Flags on the daemon itself:

```sh
parrot --no-overlay              # no pill for this run
parrot --dump-wav                # write each capture to /tmp/parrot-last.wav
parrot --debug-hotkey            # print every keyboard event the tap sees
```

`parrot doctor` is the one worth keeping in the terminal — it works over ssh, where a settings window doesn't.

`parrot install --launch-at-login` / `--uninstall` still work as aliases for `start` / `stop`, as does `parrot cleanup set-key` for `parrot key set`.

## Privacy, in one place

- **Audio** stays on the Mac unless you deliberately pick `gpt-transcribe` — that goes for a file you hand it as much as for the microphone.
- **Dictation** reads one thing about the app in front: its bundle id, for matching a style category. Turn integrations on and it also reads the *names* in the window — never the prose, never stored.
- **Squawk** reads the front window's contents, only while you hold the key, only when it's switched on, and sends them off the machine only if you picked a remote provider. Never stored.
- **Cleanup** sends the transcript to whichever provider you chose. Apple's runs on-device.
- **Never read, at any setting**: 1Password, Bitwarden, LastPass, Dashlane, KeePass, Keychain Access, the login window, parrot itself, and any secure text field at any depth.
- **Keys** live in the Keychain. **History** is a local `0600` file you can clear or switch off.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```

### The app bundle

```sh
./scripts/bundle.sh              # ad-hoc signed, for local testing
./scripts/bundle.sh --notarize   # Developer ID + notarize + staple
```

Produces `dist/parrot.app` and a drag-to-install `dist/parrot-<version>.dmg`.

Both the app icon and the DMG background are rendered at build time from the same bird glyph the menu bar uses (`scripts/make-icon.swift`, `scripts/make-dmg-background.swift`), so there's no binary asset in the repo.

Signing picks up a "Developer ID Application" cert automatically; set `SIGN_IDENTITY` to pin a specific one. Notarizing needs credentials stored once:

```sh
xcrun notarytool store-credentials parrot \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Only a notarized build opens on someone else's Mac without Gatekeeper blocking it.

## Stack

- **Swift** — one SPM executable target, no sidecars, no HTTP servers
- **FluidAudio** — Parakeet TDT inference via CoreML, ANE-accelerated
- **AVAudioEngine** / **CoreAudio HAL** — mic capture and device enumeration
- **CGEventTap** — global hotkey, listen-only
- **CGEvent** — text injection at the cursor
- **Accessibility (AX)** — reading the screen for squawk, and names for integrations
- **NSWindow** (borderless, click-through) — the recording pill
- **SwiftUI** — settings, onboarding and the pill's contents
- **FoundationModels** — the on-device provider for cleanup and squawk (macOS 26+)

See [docs/architecture.md](docs/architecture.md) for why it's shaped this way.

## License

MIT. See [LICENSE](LICENSE).
