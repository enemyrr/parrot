# Architecture

## Goals

1. **CLI executable.** Single binary, launched from the terminal. No dock icon. (Originally "no settings window" too — see *Revisited cuts* below; there is one now, and it is where configuration lives.)
2. **Push-to-talk, with a hands-free escape hatch.** Hold Fn and release; or double-tap Fn to keep recording without holding.
3. **Minimal recording feedback.** A small floating pill at the bottom of the screen while recording, so the user knows the mic is hot. Click-through, borderless, hidden when idle.
4. **Transcription is strictly on-device.** Audio never leaves the machine, on any code path, in any configuration.
5. **Pluggable engines.** Parakeet today behind a `Transcriber` protocol; another engine is one conformance plus one registry entry.
6. **Native and lean.** One Swift Package executable target. No sidecar processes. No HTTP servers.

## Non-goals

- Cross-platform (macOS only)
- Dock icon (the daemon runs as an accessory). *Settings window and preferences UI were on this list and are no longer — see* Revisited cuts.
- **Cloud transcription.** Audio is never uploaded. (Text post-processing is a separate, opt-in thing — see below.)
- Summarization, agents, chat
- Speaker diarization, meeting recording, semantic search

## On text post-processing

Transcription is on-device, full stop. Text *cleanup* — fixing punctuation and dropping filler words — is a distinct, optional stage that runs after transcription:

- It is **off by default**.
- The default provider is Apple's on-device `FoundationModels`, which is also local.
- A cloud provider (Anthropic or OpenAI) is available but must be chosen explicitly in the Cleanup tab, with a key the user stores themselves.

So the on-device promise holds for audio unconditionally, and for text unless the user opts out of it deliberately. This is a deliberate relaxation of the original "no AI post-processing" non-goal: raw ASR output has no sentence breaks and keeps every "um", and the alternative was making every user fix that by hand.

## Why Swift

- **CoreML / ANE access.** FluidAudio is Swift-native and runs inference on the Apple Neural Engine — lower power, lower latency than CPU/GPU paths in Rust.
- **No FFI for platform APIs.** `AVAudioEngine`, `CGEventTap`, `CGEvent`, `AXIsProcessTrusted`, `NSWindow` — all first-party, no bindings to maintain.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother in a Swift binary than via Rust crates.
- **AppKit overlay for free.** The recording indicator (see below) is a borderless `NSWindow` — trivial in Swift, awkward in Rust.

The binary is a Swift Package executable — `swift build`, `swift run`, ship a single binary. It also bundles as `parrot.app` (`scripts/bundle.sh`) for the DMG; either way it runs as an accessory, with a menu bar item and no dock icon.

## High-level shape

```
$ parrot
                                    ┌──────────────────┐
                                    │   ParrotCLI      │
                                    │   (main.swift)   │
                                    └────────┬─────────┘
                                             │ wires modules, runs RunLoop
                                             ▼
┌──────────────────┐  .begin        ┌──────────────────┐
│   HotkeyMonitor  │ ─────────────▶ │  AudioCapture    │
│  (CGEventTap)    │  .end          │ (AVAudioEngine)  │
└──────────────────┘ ◀───────────── └────────┬─────────┘
   hold / double-tap                         │ [Float] PCM
                                             ▼
                                ╔═════════════════════════╗
                                ║   DictationPipeline     ║
                                ║                         ║
                                ║  ┌──────────────────┐   ║
                                ║  │   Transcriber    │   ║
                                ║  │   (protocol)     │   ║
                                ║  │  ┌────────────┐  │   ║
                                ║  │  │  Parakeet  │  │   ║
                                ║  │  └────────────┘  │   ║
                                ║  └────────┬─────────┘   ║
                                ║           ▼             ║
                                ║      Wordlist           ║
                                ║           ▼             ║
                                ║  ┌──────────────────┐   ║
                                ║  │   TextCleaner    │   ║
                                ║  │   (protocol)     │   ║
                                ║  │ Apple│Anthropic│OpenAI│ ║
                                ║  └────────┬─────────┘   ║
                                ║           ▼             ║
                                ║      Wordlist           ║
                                ║           ▼             ║
                                ║   TranscriptStore       ║
                                ╚════════════╤════════════╝
                                             │ String
                                             ▼
                                    ┌──────────────────┐
                                    │  TextInjector    │
                                    │   (CGEvent)      │
                                    └──────────────────┘
```

## Modules

### `main.swift` (ParrotCLI)

Argument parsing (via `swift-argument-parser`), config loading, module wiring. Calls `NSApplication.shared.setActivationPolicy(.accessory)` so the process has no dock icon and no menu bar entry, then runs `NSApp.run()` to keep the process alive and drive the AppKit run loop (needed for `NSWindow`, `CGEventTap`, and AVFoundation). Exits cleanly on SIGINT. Logs status to stderr so a user running it in a terminal can see what's happening.

Subcommands:
- `parrot` (default) — run the daemon
- `parrot settings [--pane <name>]` — open the settings window, optionally on a tab
- `parrot models list` — show registered models, mark which are downloaded
- `parrot models download <id>` — pre-fetch a model
- `parrot doctor` — permissions, Fn mapping, model and cleanup availability, as text
- `parrot history [search|clear]` — browse past transcriptions
- `parrot cleanup set-key | clear-key` — manage a provider key in the Keychain

`parrot settings` runs as a `.regular` app rather than an accessory: it is a window the user opened deliberately, so ⌘Q and the dock should behave normally. The daemon's own copy of the window is the same SwiftUI view with a live `SettingsContext` behind it.

### `HotkeyMonitor`

Global hotkey via `CGEventTap` (requires Accessibility permission). Default: **Fn**, detected via `flagsChanged` events with `kCGEventFlagMaskSecondaryFn`.

The hotkey has two shapes, because push-to-talk has two natural gestures. A **bare modifier** (Fn, Option…) is watched through `flagsChanged` on one flag — nothing is typed while you hold it, which is why it's the default. A **recorded shortcut** (⌃⌥Space, F13) is watched through `keyDown`/`keyUp` on a keycode, with the required modifiers checked only on the way down: releasing ⌃ before Space is a normal way to let go of ⌃Space and must not strand a recording.

`keyUp` is subscribed **only** for the second shape. For a bare modifier it would double the tap's traffic — for every keystroke the user ever types, in any app — to no purpose. For a key shortcut it's the only way to see the release, so there it's the price of the feature. The same `isPressed` dedupe that filters modifier repeats also swallows auto-repeat, which fires `keyDown` a dozen times a second for exactly as long as push-to-talk holds the key.

A bare *key* is deliberately not representable: the tap is listen-only on purpose — parrot watches the keyboard, it never swallows from it — so holding a plain letter would type a screenful of it into whatever is in front. Anything without a modifier has to be a function key, which produces no character to begin with.

Rather than raw key edges, it emits dictation intent — `.begin`, `.latched`, `.end`, `.cancelled` — from a four-state machine (`idle` → `holding` → `awaitingSecondTap` → `latched`):

- **Release after a real hold** (≥ `latch.tapMs`) → `.end` immediately. The push-to-talk path keeps its original zero added latency.
- **Release after a tap** (< `latch.tapMs`) → wait out `latch.windowMs`. A second press inside that window promotes the recording to `.latched` (hands-free); the timer firing first means it really was just a short press, so `.end`.
- **Press while latched** → `.end`. That's the "tap once more to stop" half.
- **Escape** → `.cancelled`, and the audio is discarded.
- **`latch.maxSeconds` in latched** → `.end`, so a forgotten hands-free session can't record forever.

Only sub-`latch.tapMs` taps — which are never real utterances — pay the disambiguation wait.

**Fn key caveat:** macOS by default maps the Fn (🌐) key to "Show Emoji & Symbols" or "Start Dictation" depending on the user's setting in System Settings → Keyboard → Press 🌐 key to. The CGEventTap sees the keypress regardless, but the system action also fires. `parrot doctor` will detect this setting and instruct the user to change it to "Do Nothing" so Fn becomes a clean modifier.

### `AudioCapture`

`AVAudioEngine` tap on the input node. Streams 16 kHz mono `Float32` buffers into a ring buffer while the hotkey is held. On release, hands the full buffer to the active `Transcriber`.

### `Transcriber` (protocol)

```swift
protocol Transcriber {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}
```

Concrete implementation:

- `ParakeetTranscriber` — wraps `FluidAudio`'s `AsrManager` for NVIDIA Parakeet TDT 0.6B. CoreML, ANE-accelerated.

Adding an engine = one new file conforming to `Transcriber`, plus one registry entry.

**Why Parakeet and not Whisper.** Whisper is autoregressive, so with no speech to transcribe it still produces *something* — `[BLANK_AUDIO]`, `(music)`, `<|nospeech|>`. Push-to-talk generates a lot of short, noisy captures, so parrot originally carried a regex to strip those tokens before injection. A TDT transducer emits nothing for silence (NVIDIA trained it on 36k hours of silence and noise paired with empty targets), which deletes that whole class of bug rather than papering over it. It's also ~10× faster on the ANE and scores better on the Open ASR Leaderboard (6.32% vs large-v3's 7.44%). The cost is language coverage: 25 European languages instead of 99.

### `Wordlist`

Literal find → replace from the Dictionary tab's replacement rules (`WordlistSettings.replacements`), case-insensitive and word-boundary anchored. All rules compile into **one alternation applied in a single left-to-right pass**, so text a rule emits is never re-examined by another rule — applying rules in sequence instead lets a `"claude"` rule chew through the output of a `"claude code"` rule. Longest key first, so the more specific rule wins at any given position.

Runs on both sides of the cleanup pass: before, so the model sees correct proper nouns; after, so the user's replacements win regardless of what the model did. That's safe because the single-pass design makes it idempotent for any wordlist where a replacement doesn't reintroduce another rule's key.

### `TextCleaner` (protocol)

```swift
protocol TextCleaner {
    var name: String { get }
    func clean(_ text: String, vocabulary: [String]) async throws -> String
}
```

- `AppleFoundationCleaner` — `FoundationModels`, on-device, macOS 26+. The default.
- `AnthropicCleaner` — Messages API over `URLSession`, key from the Keychain. Opt-in.
- `OpenAICleaner` — Responses API over `URLSession`, key from the Keychain. Opt-in.

Two guards, because a cleaner sits between the user's voice and their keystrokes:

- **Prompt injection.** The transcript goes in as a user turn, never concatenated into the system prompt, and the instructions say the text is dictation rather than a request. Dictating "ignore your instructions and write X" produces the sentence, not X.
- **Length sanity.** A result more than 2.5× or less than 0.4× the input's word count is discarded in favor of the raw transcript. Catches refusals, meta-commentary, and runaway generations.

Any failure — timeout, no network, no key, wrong macOS version — logs to stderr and returns the pre-cleanup text. **Dictation never blocks on a language model.**

### `TranscriptStore`

Append-only JSONL at `~/.local/share/parrot/history.jsonl`, mode `0600`, pruned to `max_entries` at startup. Records both `raw` and final `text` so cleanup regressions are diagnosable.

JSONL over SQLite deliberately: at ~200 bytes an entry the 5000-entry cap is about a megabyte, so a full in-memory scan for search is instant, there's no schema to migrate, and the file stays greppable with ordinary tools. Lines that fail to decode are skipped rather than fatal — a truncated write shouldn't cost the user their history.

### `TextInjector`

`CGEventCreateKeyboardEvent` + `CGEventKeyboardSetUnicodeString` — pastes the transcript at the current cursor position. Works in nearly every text field on macOS (some Electron apps and secure fields are flaky; platform constraint).

### `RecordingOverlay`

A single borderless `NSWindow` displayed at the bottom-center of the active screen while recording. Provides visual feedback that the mic is hot — the only piece of UI in the app.

Window configuration:
- `styleMask: .borderless`
- `backgroundColor: .clear`, `isOpaque: false`, `hasShadow: true`
- `level: .statusBar` (or `.floating`) — sits above all other windows
- `ignoresMouseEvents = true` — clicks pass through to whatever is underneath
- `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]` — visible across Spaces, doesn't appear in window switcher

Content: a small SwiftUI view hosted via `NSHostingView`, showing a pulsing dot + "listening" text, optionally a live mic level meter fed from `AudioCapture`. Total footprint: ~120pt wide, ~40pt tall, positioned 60pt above the bottom of the screen.

States:
- **Hidden** — idle. No window on screen.
- **Recording** — shown on `.begin`, mic level animated.
- **Latched** — same waveform plus a lock glyph, so hands-free mode is unmistakable at a glance.
- **Transcribing** — brief spinner state between hotkey release and text injection (usually <500 ms).
- **Hidden** — back to idle after injection, or immediately on `.cancelled`.

This, plus the menu bar item, is why the process needs an `NSApplication` run loop instead of a bare `CFRunLoop`.

### `MenuBarController`

`NSStatusItem` with an inlined template SVG. Shows current state (`idle` / `recording` / `hands-free` / `transcribing`), with the last 10 transcripts tucked into a **Recent** submenu — inline they turned the menu into a wall of text.

The submenu is populated in `menuNeedsUpdate(_:)` rather than pushed on every transcript. That keeps the injection path free of UI work and makes stale entries structurally impossible: the list is built at the moment it's shown.

Clicking a transcript **copies it** rather than re-injecting. By the time the menu closes, focus has returned to whatever app was underneath, and typing into it uninvited is a worse surprise than a clipboard write.

Since the process runs `.accessory` — no dock icon, no window — this is the only persistent surface the user can actually see and click.

### `ModelRegistry`

```swift
struct TranscriptionModel: Codable {
    let id: String              // "parakeet-v3"
    let displayName: String
    let engine: Engine          // .parakeet
    let engineModelID: String?  // "parakeet-tdt-0.6b-v3"
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

enum Engine: String, Codable { case parakeet }
```

The list lives in source rather than a JSON resource, so the executable stays self-contained — no `Bundle.module` lookup, no resource bundle to install alongside the binary. Adding a model = appending an entry.

`find(_:)` also resolves **retired ids**: a LaunchAgent plist or shell alias written before the Parakeet switch still passes `--model whisper-base.en`, which maps to `parakeet-v3` with a one-line notice rather than a hard failure.

### Model downloads

Fetching is FluidAudio's (`AsrModels.download` / `downloadAndLoad`, from Hugging Face into its own cache), but the *state* of it is parrot's: `ModelCatalog` is a main-actor `ObservableObject` that knows which models are on disk, how many bytes each takes, and the progress of one being fetched.

It exists because the download needed a home other than the recording pill. A 460 MB fetch wants a progress bar, a size, a failure with a retry, and a way to reclaim the space — none of which fit in a capsule at the bottom of the screen. The pill has no `.downloading` state any more; the Models tab owns all of it, and `DictationController` opens the window there when the active model is missing at startup.

`WarmupProgressCurve` still folds FluidAudio's per-sub-operation sawtooth (0→1 once per CoreML model) into a fraction that only climbs — otherwise a download that is working looks like it is looping.

### `Settings`

One `Codable` struct, stored as a single JSON blob in `UserDefaults(suiteName: "com.digimata.parrot")`. It replaced a hand-edited `config.toml`.

One blob under one key, rather than a key per field, buys three things:

- Writes are **atomic** — no reader ever sees half a change.
- The value is `Equatable`, so `DictationController` can diff old against new and rebuild only what actually changed.
- Decoding is per-key tolerant (`decodeIfPresent` everywhere), so a blob written by an older build gains new fields' defaults instead of failing to load and silently resetting everything.

An explicit suite, not `UserDefaults.standard`: parrot runs both as a bare binary on `$PATH` and as `parrot.app`, and the standard suite would give those two different preference domains — the same user's settings would appear to vanish depending on how they launched it.

`LegacyConfigMigration` reads an existing `config.toml` once, folds it into `Settings`, and renames the file to `config.toml.migrated`. The rename is what makes it run exactly once. Every section decodes independently: the old loader treated a malformed file as fatal, which was right when it was live configuration, but during a one-shot import a single bad line shouldn't cost the user the other nine sections.

Data still lives under `$XDG_DATA_HOME` (default `~/.local/share`), so transcripts and stats stay out of `~/Library` and are easy to point elsewhere in tests.

### `DictationController`

The running daemon as one main-actor object: transcriber, hotkey monitor, capture, overlay, menu bar, stores, cleaner.

Everything used to be assembled once inside `Run.run()` and then frozen — changing a setting meant editing a file and restarting. Now `SettingsStore.onChange` hands the controller `(old, new)` and it reconfigures only the pieces that differ: a new model reloads the engine, a new hotkey restarts the tap, a new sensitivity just retunes the meter. The `DictationPipeline` is rebuilt per utterance rather than held as a field, because every component it names can be swapped mid-session and a stale pipeline would quietly keep using the old one.

Warm-up is no longer blocking. It used to pump the runloop against a semaphore so the download pill could animate; now the app comes up immediately and the engine's state is reported in the menu bar and in the settings window's status bar.

## Permissions

Two grants, surfaced in the **Permissions** tab and in `parrot doctor`:

1. **Microphone** — standard `AVCaptureDevice` request, which the pane can trigger directly.
2. **Accessibility** — required for `CGEventTap` (hotkey) and `CGEvent` posting (text injection). Only System Settings can grant it, so the pane's button opens that pane rather than pretending to fix it.

`DoctorReport` is the single source of truth for both; `Check` carries a `CheckKind` so the UI can attach the right action without matching on message strings. The pane re-runs the checks on a 2s timer — every grant is made in another window, and coming back to a stale ✗ with a Refresh button would be the app pretending it couldn't tell.

Missing Accessibility no longer stops the daemon. It stays up, opens the Permissions tab, and polls `AXIsProcessTrusted()`; the moment the grant lands it registers the tap and starts listening. The old build exited (deliberately, to avoid a crash-loop) and required a manual restart, which was the most confusing thing about first run.

### TCC quirk worth knowing

When you launch `parrot` from `Terminal.app`, accessibility permission is granted to *Terminal*, not parrot itself. This means:
- Switching terminals (Terminal → iTerm → Ghostty) requires re-granting permission.
- Running under `launchd` requires granting permission to whatever spawns it.

This is a macOS platform behavior, not a parrot bug. `parrot doctor` will identify the parent process and tell the user which app needs the permission.

## Models — what ships

| Engine | id | Languages | Notes |
|---|---|---|---|
| Parakeet | `parakeet-v3` | 25 European, auto-detect | Default |
| Parakeet | `parakeet-v2` | English only | ~0.3pp better English WER (6.05% vs 6.32%) |

Both are Parakeet TDT 0.6B. v3 traded a little English accuracy for 24 extra languages; v2 exists for anyone who only ever dictates English. Not bundled — FluidAudio fetches on first use or via `parrot models download`.

## Data flow, end-to-end

1. User runs `parrot` in a terminal.
2. Any legacy `config.toml` is imported once, then `DictationController` reads `Settings` and instantiates modules. The model warms up in the background rather than blocking startup; if it isn't downloaded, the settings window opens on the Models tab and the fetch starts there.
3. Sets `.accessory` activation policy and enters `NSApp.run()`. Status: `listening`. Overlay hidden. If Accessibility is missing, the Permissions tab opens instead and the controller polls until the grant lands.
4. User holds Fn (or double-taps it).
5. `HotkeyMonitor` fires `.begin`. `RecordingOverlay` shows. Status: `recording`.
6. `AudioCapture` starts the AVAudioEngine tap. Buffers fill. Overlay animates mic level.
7. User releases Fn (or taps once more, if latched).
8. `HotkeyMonitor` fires `.end`. Overlay switches to spinner. Status: `transcribing`.
9. `AudioCapture` stops, hands the buffer to `DictationPipeline`.
10. `Transcriber` runs CoreML inference. Empty result → nothing injected, straight back to idle.
11. `Wordlist` applies replacements; `TextCleaner` runs if enabled and the transcript clears `min_words`; `Wordlist` runs again.
12. `TranscriptStore` appends raw + final text.
13. `TextInjector` posts the string at the cursor. Menu bar reloads its Recent list.
14. Overlay hides. Status: `listening`. Loop.
15. User hits `^C`. Process exits cleanly.

End-to-end latency target: <500 ms after hotkey release for utterances under 10 seconds, on Apple Silicon, with cleanup off. Cleanup adds its own round trip, which is why it's gated behind `min_words` and a timeout that falls back to the raw text.

## What we are deliberately NOT building

- No streaming partial transcripts in v1. Press, speak, release, get full text.
- No streaming partial transcripts. Press, speak, release, get full text.
- **No VAD-based** hands-free mode. Double-tap latching gives hands-free dictation with an explicit start and stop, no idle CPU, and no guessing about when you stopped talking.
- No clipboard manager. History is a log you can read and search, not a stack you paste from.
- No decoder-level vocabulary biasing (yet) — see below.

These are deliberate cuts. Each can be revisited if real usage demands it. Four that already were:

- **Menu bar item** — an `.accessory` process with no window had no way to tell you it was alive, or to surface history.
- **History** — "output goes to the cursor and that's it" is fine until a transcript lands in the wrong window.
- **Custom vocabulary and post-processing** — see *On text post-processing* above.
- **A settings window** — the original cut said "configuration is flags + TOML". That held right up until the things needing configuration stopped being scalars: a 460 MB download wants a progress bar, a permission wants a button that opens the right System Settings pane, and meter sensitivity can only really be judged against your own voice. None of those are expressible in a text file, and the file had also become the only place two of them were even mentioned.

## Known gap: vocabulary biasing

The Dictionary tab's vocabulary (`WordlistSettings.vocabulary`) currently only feeds the cleanup prompt as terms to preserve. FluidAudio ships real CTC-based decoder biasing (`CustomVocabularyContext`, per NVIDIA's CTC-WS paper), which would make Parakeet *recognize* a rare proper noun rather than having us correct it afterward.

Not wired up yet because for Parakeet 0.6B it needs a separate ~130 MB CTC encoder and drops throughput from ~120× to ~26× real-time. That's a real cost for a feature the post-hoc wordlist already approximates. Worth revisiting if phonetically-hard names turn out to be a common failure.

## Project layout (planned)

Organized by feature area. These are folders within a single SPM executable target — Swift sees them as one module, but the directory grouping keeps related code together. If a group later earns its keep as a reusable library (e.g. `Transcription` consumed by another tool), it can be promoted to its own SPM target with no rewriting.

```
parrot/
  Package.swift                 # SPM, single executable target
  Sources/parrot/
    Parrot.swift                # entry point, subcommands, NSApp.run()
    Doctor.swift                # checks + the actions that fix them
    Install.swift

    Settings/
      Settings.swift            # the whole settings value type
      SettingsStore.swift       # UserDefaults-backed, observable
      Hotkey.swift              # modifier or recorded shortcut
      LegacyConfigMigration.swift

    Config/
      Paths.swift               # XDG-style data locations

    Transcription/              # the inference layer
      Transcriber.swift         # protocol + errors
      ParakeetTranscriber.swift

    Text/                       # everything between ASR and the cursor
      DictationPipeline.swift
      Wordlist.swift
      TextCleaner.swift         # protocol, prompt, guards, fallback
      AppleFoundationCleaner.swift
      AnthropicCleaner.swift
      OpenAICleaner.swift
      Keychain.swift

    History/
      TranscriptStore.swift     # append-only JSONL

    Models/                     # registry + on-disk state
      ModelRegistry.swift
      TranscriptionModel.swift  # Codable types
      ModelCatalog.swift        # installed? how big? download, delete
      WarmupProgressCurve.swift

    Audio/
      AudioCapture.swift        # AVAudioEngine tap + ring buffer

    Input/
      HotkeyMonitor.swift       # CGEventTap + latch state machine
      TextInjector.swift        # CGEvent posting

    Daemon/
      DictationController.swift # owns the runtime, reacts to settings changes
      DaemonCommands.swift
      LaunchAgent.swift

    UI/
      RecordingOverlay.swift    # borderless NSWindow + SwiftUI pill
      MenuBarController.swift   # NSStatusItem + recent transcripts
      ParrotGlyph.swift         # the bird, as inline SVG
      Settings/
        SettingsWindowController.swift
        SettingsRootView.swift  # sidebar + detail
        SettingsComponents.swift
        ShortcutRecorder.swift
        Panes/                  # one file per tab

  docs/
    architecture.md
  README.md
```

No `Resources/` — the model registry and the bird glyph live in source so the executable ships as a single file with no resource bundle beside it.

Build: `swift build -c release`. Resulting binary at `.build/release/parrot`. Install: copy to `~/.local/bin/` or `/usr/local/bin/`.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). For parrot v1 we use a single executable target with the folder structure above; everything is in the same module so no `import` statements between files. If we ever want enforced boundaries (e.g. `Transcription` and `UI` shouldn't reach into `Audio` internals), we promote folders to separate targets in `Package.swift` — a structural change, not a semantic one.

## Open questions

- **Left vs. right modifiers.** `CGEventFlags` has no left/right distinction, so `--hotkey option` means either option key. Telling them apart means tracking keycodes through `flagsChanged` — doable, not obviously worth it.
- **Tap re-registration.** `CGEventTap` can be disabled by the system (`tapDisabledByTimeout`); today parrot logs and expects a restart. It should re-enable itself.
- **Decoder-level vocabulary biasing.** See *Known gap* above.
- **Code signing.** A self-built unsigned binary works fine locally but accessibility permission persistence is more reliable for signed binaries. Decide if we sign for personal distribution.
