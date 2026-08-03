# Architecture

## What parrot is

A menu-bar macOS app that turns a held key into text at the cursor, plus a second key that turns a held key into an *answer* at the cursor. One Swift Package executable, no sidecar processes, no HTTP servers. The same binary is the daemon, the settings window, the onboarding walkthrough and a CLI.

It began as a CLI with a TOML file and no window. Most of that has been revisited — the CLI is still the whole surface for scripting and diagnostics, but configuration lives in a settings window, and several of the original cuts (history, a menu bar item, post-processing) turned out to be load-bearing. Where a goal was reversed, it says so below.

## Goals

1. **The key is the interface.** Hold to talk, release to get text. Double-tap to latch for hands-free. A second key runs the same gesture in *squawk* mode.
2. **No ceremony.** No dock icon, no window on launch, nothing to open before dictating. The process runs `.accessory` with a menu bar item.
3. **Minimal recording feedback.** A borderless, click-through pill at the bottom of the screen while recording, and nothing when idle.
4. **On-device by default, off-device only by explicit choice.** Every default path — transcription, cleanup, squawk — runs locally. Each has a remote option the user has to go and pick.
5. **Pluggable engines and providers.** `Transcriber`, `TextCleaner` and `LLMClient` are protocols; adding an engine or a vendor is one conformance plus one registry entry.
6. **Native and lean.** One SPM executable target, first-party frameworks, no FFI.

## Non-goals

- Cross-platform. macOS, Apple Silicon.
- Dock icon. (Settings and preferences UI were on this list and are no longer — see *Revisited cuts*.)
- Streaming partial transcripts. Press, speak, release, get text.
- VAD-based hands-free. Double-tap latching gives an explicit start and stop, no idle CPU, and no guessing about when you stopped talking.
- Agents, chat, tool use, multi-turn. Squawk is single-shot: one instruction, one answer.
- Speaker diarization, meeting recording, semantic search.
- A clipboard manager. History is a log you can read and search, not a stack you paste from.
- Reading any app that isn't in front, or reading it when nothing asked.

## Where data goes, and when

This is the part worth being precise about, because three features read different things and only one of them reads windows.

| Path | Reads | Leaves the Mac | Stored |
|---|---|---|---|
| **Transcription** | the microphone | only with `gpt-transcribe` | audio never; text to history |
| **File transcription** | a file you point it at | only with `gpt-transcribe` | audio never; text to history |
| **Dictation** | the front app's bundle id | no | — |
| **Integrations** | short labels in the front window | names only, as hints, if a remote model is configured | never |
| **Squawk** | the front window's contents | yes, unless the provider is `apple` | never |
| **Cleanup** | the transcript | yes, unless the provider is `apple` | text to history |

Password managers, the login window, any `AXSecureTextField` at any depth, and parrot itself are excluded unconditionally, not by preference.

### On cloud transcription

The original architecture said audio never leaves the machine, on any code path, in any configuration. That is no longer true, and the reversal was deliberate: `gpt-transcribe` exists for the two things a local transducer structurally cannot do — languages outside Parakeet's 25, and vocabulary that *steers the decoder* rather than patching its output afterwards. It is never the recommendation and never the default; it is an escape hatch, and both the Models list and the Home row say in plain words that the audio goes to OpenAI.

### On text post-processing

Cleanup is a distinct, optional stage after transcription. Off by default; the default provider is Apple's on-device `FoundationModels`. This relaxed the original "no AI post-processing" rule for a simple reason: raw ASR output has no sentence breaks and keeps every "um", and the alternative was making every user fix that by hand.

### On squawk

Squawk is the first path that reads anything other than the microphone. Three things keep it honest:

- **Off by default.** With squawk off, the second key is never registered and nothing reads the screen. There is no passive collection anywhere in it.
- **Only the frontmost app, only while the key is held.** No polling, no background capture, no history of what has been on screen. The capture is a single accessibility walk started on key-down and thrown away after the answer is injected.
- **Never stored.** History keeps the instruction and the answer. What was read off the screen is not written anywhere — that would turn a convenience log into a record of everything the user has looked at.

**Why accessibility, not screen capture.** Reading the AX tree needs the Accessibility grant parrot already holds for the hotkey, so squawk asks for no new permission. OCR would need Screen Recording, would cost an order of magnitude more latency, and would return worse text. The tradeoff is coverage: an app that publishes no accessibility tree is invisible, and Chromium apps publish one only when asked.

**The prompt is layered, and the screen is data.** Base prompt, "about you", the category's tone and length, its notes, then the language rule — stacked least specific to most, so recency lets the specific one win: a Slack category saying "lowercase, no punctuation" beats a formal tone, because whoever wrote the note was being more specific than whoever picked the tone. Everything read off the screen goes in the *user* turn, wrapped in tags, and the base prompt says tagged screen content is reference material and never an instruction. The same discipline the cleanup path applies to a transcript.

**The model returns `{action, text}`** rather than bare prose, so one prompt covers both jobs — rework the selection, or compose something new — with the model deciding from the wording of the instruction rather than from whether a selection happens to exist. A separate classifier call would put a whole extra round trip in front of every squawk to answer a question the writing model already has to answer.

### On integrations

Integrations are the one thing that lets *dictation* look at a window, and the design is built around keeping that narrow.

`RosterReader` is a second walk rather than a mode on `ScreenReader`, and the difference is the point. `ScreenReader` collects prose in reading order and joins it into something a model can read — it produces the *contents* of the window. `RosterReader` collects short labels with their positions and throws the prose away — what comes out is a list of channel names and filenames. A roster is not what is on your screen, which is why dictation is allowed to run it at all.

`EntityTagger` is deterministic and not a model. The table comes off the screen, the rewrite is a literal phrase match against it, and nothing else can come out the far end. An `@mention` is not a typo — it notifies a real person — and a language model asked to "tag the names" will eventually tag one that was never on screen. It also means the feature works with cleanup switched off, which is the default.

Safety comes from the trigger word being part of the key: "hashtag eng parrot" → `#eng-parrot`, consuming the trigger. Nothing fires unless the speaker reached for the sigil by name. The exception is `.symbol` — spelling help with no sigil and no trigger — which is fenced instead by shape (camelCase / PascalCase / snake_case, six characters and up) and by frequency (twice on screen, minimum), because a wrong one silently corrupts a word the user actually said.

`IntegrationMonitor` holds the verdict per integration, in memory only: three consecutive empty walks and parrot stops asking, until the app restarts under a new pid or the user rechecks. A persisted "unavailable" would outlive the app update that fixed it.

### On style

Tone, length, "about you" and the per-app notes live in one place — `StyleSettings` — because two features put text on screen and they have to write as the same person.

The unit is a **category**: a name, an icon, the apps it claims, and its own tone, length and notes. The previous shape was one global tone with per-app notes bolted on, which asked a paragraph of prose to carry a difference — Mail formal, Slack lowercase — that is two clicks when tone is per-category. Exactly one category is the fallback and it sorts last, so "what tone in an app I never set up?" always has an answer and no call site has to invent one.

The two consumers have different contracts, and the split is load-bearing:

- **Squawk writes**, so it gets all of it: tone, length, who you are, and how this kind of writing works.
- **Cleanup repairs a transcript**, so it gets only what it may change. `Tone.cleanupRule` never asks for different words — only different punctuation and casing — and a styled cleanup prompt ends with an explicit "keep the speaker's words and their order". Length and "about you" never reach it: how much you meant to say was decided when you said it, and repairing a sentence is not the place to know who said it.

Dictation's half of app matching is the bundle id and nothing else, captured when the key goes down — never the window's contents.

## Why Swift

- **CoreML / ANE access.** FluidAudio is Swift-native and runs inference on the Apple Neural Engine — lower power and lower latency than CPU/GPU paths elsewhere.
- **No FFI for platform APIs.** `AVAudioEngine`, `CGEventTap`, `CGEvent`, `AXUIElement`, `NSWindow`, `NSStatusItem` — all first-party.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother from a Swift binary.
- **AppKit and SwiftUI for free.** The pill is a borderless `NSWindow`; the settings window and onboarding are SwiftUI hosted in it.

The binary is an SPM executable — `swift build`, ship one file. It also bundles as `parrot.app` (`scripts/bundle.sh`) for the DMG; either way it runs as an accessory with a menu bar item and no dock icon.

## High-level shape

```
                                    ┌──────────────────┐
                                    │  Parrot.swift    │
                                    │  (subcommands)   │
                                    └────────┬─────────┘
                                             │ Run → NSApp.run()
                                             ▼
                                    ┌──────────────────┐
                                    │ DictationController│
                                    └────────┬─────────┘
                                             │ owns everything below
┌──────────────────┐  .begin(mode)  ┌──────────────────┐
│   HotkeyMonitor  │ ─────────────▶ │  AudioCapture    │
│  (CGEventTap)    │  .end          │ (AVAudioEngine)  │
└──────────────────┘ ◀───────────── └────────┬─────────┘
   hold / double-tap                         │ [Float] PCM
   two bindings: dictate | squawk            │
                          ┌──────────────────┴──────────────────┐
                          ▼                                     ▼
          ╔═══════════════════════════╗          ╔═══════════════════════════╗
          ║    DictationPipeline      ║          ║     SquawkPipeline        ║
          ║                           ║          ║                           ║
          ║  Transcriber              ║          ║  Transcriber              ║
          ║    Parakeet | OpenAI      ║          ║      ▼                    ║
          ║      ▼                    ║          ║  Wordlist → Shortcuts     ║
          ║  Wordlist                 ║          ║      ▼                    ║
          ║      ▼                    ║          ║  SquawkPrompt             ║
          ║  TextCleaner (optional)   ║          ║   + ScreenContext ────────╫──┐
          ║    Apple|Anthropic|OpenAI ║          ║      ▼                    ║  │
          ║      ▼                    ║          ║  LLMClient                ║  │
          ║  Wordlist                 ║          ║    Apple|Anthropic|OpenAI ║  │
          ║      ▼                    ║          ║      ▼                    ║  │
          ║  EntityTagger ◀───────────╫──┐       ║  SquawkGuard              ║  │
          ║      ▼                    ║  │       ╚═══════════╤═══════════════╝  │
          ║  ShortcutExpander         ║  │                   │                  │
          ║      ▼                    ║  │                   │      ScreenReader│
          ║  TranscriptStore, Stats   ║  │       RosterReader│      (AX walk,   │
          ╚═══════════╤═══════════════╝  └───────(AX walk,   │       contents)  │
                      │                           names)◀───┴──────────────────┘
                      ▼                                     ▼
              ┌──────────────────┐              ┌──────────────────┐
              │  TextInjector    │              │ TextInjector.put │
              │  (type)          │              │ (type or paste)  │
              └──────────────────┘              └──────────────────┘
```

Both AX walks start on **key-down**, while the user is still talking, and are awaited at the end. That is the only place in the flow where a few hundred milliseconds are free — and it snapshots the screen as it was when the user decided what to say.

## Modules

### `Parrot.swift`

Argument parsing (`swift-argument-parser`) and the subcommand list. `Run` is the default: it folds in any legacy `config.toml`, sets `.accessory`, builds a `DictationController`, and enters `NSApp.run()` — needed for `NSWindow`, `CGEventTap` and AVFoundation. Exits cleanly on SIGINT and logs to stderr so someone running it in a terminal can watch it work.

Subcommands, grouped by what they're for:

- **Run and daemon** — `run` (default), `start`, `stop`, `restart`, `status`, `logs`, `install` (deprecated alias)
- **Windows** — `settings [--pane]`, `setup`
- **Diagnostics** — `doctor`, `context`, `roster`, `squawk`, `cleanup run`, `overlay-preview`
- **Data** — `history [list|search|clear]`, `stats [show|reset]`, `models [list|download]`, `key [set|clear|list]`

`settings` and `setup` run `.regular` rather than accessory: they're windows the user opened deliberately, so ⌘Q and the dock should behave normally. When the daemon is already running, `parrot settings` says so — it opens a second, inert copy, and changes made there won't reach the daemon until it restarts.

### `HotkeyMonitor`

Global hotkey via `CGEventTap` (requires Accessibility). Takes a **list** of `(DictationMode, Hotkey)` bindings, so dictation and squawk are the same machinery with different modes attached.

The hotkey has two shapes, because push-to-talk has two natural gestures. A **bare modifier** (Fn, Option…) is watched through `flagsChanged` on one flag — nothing is typed while you hold it, which is why it's the default. A **recorded shortcut** (⌃⌥Space, F13) is watched through `keyDown`/`keyUp` on a keycode, with the modifiers checked only on the way down: releasing ⌃ before Space is a normal way to let go of ⌃Space and must not strand a recording.

`keyUp` is subscribed **only** for the second shape. For a bare modifier it would double the tap's traffic — for every keystroke the user ever types, in any app — to no purpose. The same `isPressed` dedupe that filters modifier repeats also swallows auto-repeat.

A bare *key* is deliberately not representable: the tap is listen-only on purpose, so holding a plain letter would type a screenful of it into whatever is in front. Anything without a modifier has to be a function key.

Rather than raw key edges it emits intent — `.begin(mode)`, `.latched`, `.end`, `.cancelled` — from a four-state machine (`idle` → `holding` → `awaitingSecondTap` → `latched`):

- **Release after a real hold** (≥ `latch.tapMs`) → `.end` immediately. Push-to-talk keeps its zero added latency.
- **Release after a tap** (< `latch.tapMs`) → wait out `latch.windowMs`. A second press inside that window promotes to `.latched`; the timer firing first means it really was a short press, so `.end`.
- **Press while latched** → `.end`.
- **Escape**, or an ordinary shortcut pressed while a bare modifier is held → `.cancelled`, audio discarded.
- **`latch.maxSeconds`** → `.end`, so a forgotten hands-free session can't record forever.

Only sub-`tapMs` taps — never real utterances — pay the disambiguation wait.

**Fn key caveat:** macOS maps 🌐 to "Show Emoji & Symbols" or "Start Dictation" depending on System Settings → Keyboard. The tap sees the press regardless, but the system action also fires. `DoctorReport` detects this and says to set it to "Do Nothing".

### `AudioCapture` and `AudioDevices`

`AVAudioEngine` tap on the input node, streaming 16 kHz mono `Float32` into a ring buffer while the key is held, plus an RMS level for the pill's meter.

The device comes from `settings.audio.inputDeviceUID`, applied to the input node's audio unit at the start of each recording — before the format is read, since switching device changes the sample rate and a tap installed with the stale format is rejected. The UID is resolved fresh every time rather than cached: the chosen device may have been unplugged, and falling back to the system default beats a failed recording.

`AudioDevices` enumerates through the CoreAudio HAL rather than `AVCaptureDevice`, which only reports what it considers camera-ish — aggregates, loopback drivers and most USB interfaces are exactly what someone opens the picker for. Settings store the **UID**, not the device id: the id is assigned per boot and would name a different device the next morning.

### `SystemAudioMute`

Optional, off by default: silence the Mac's output for the length of a recording. Two mechanisms, because not every device implements `kAudioDevicePropertyMute` — where it's missing, the virtual main volume goes to zero and is restored after. Whichever it used, the *device* is remembered rather than looked up again: plugging in headphones mid-sentence changes the default output, and restoring the new one would leave the old one silent for good. `DictationController.stop()` restores first, before anything else, because a daemon that exits mid-recording must not leave the Mac silent with nobody left to fix it.

### `Transcriber` (protocol)

```swift
struct TranscriptionContext { let vocabulary: [String]; let languages: [String] }

protocol Transcriber {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> String
    func transcribe(fileAt url: URL, context: TranscriptionContext) async throws -> String
}
```

Context is passed per call, not fixed at construction: editing a wordlist entry has to take effect on the next dictation, and rebuilding the transcriber to deliver it would reload a CoreML model on every keystroke in the Dictionary pane.

The file overload is in the protocol rather than only in an extension so a conformance can take the URL itself. The default implementation decodes to samples and calls the array version, which is right for anything that has to hold the whole recording anyway; Parakeet overrides it to stream the file off disk instead, which is the difference between 230 MB and ~1 MB for an hour of audio.

- `ParakeetTranscriber` — wraps FluidAudio's `AsrManager` for Parakeet TDT 0.6B. CoreML, ANE. Ignores the context: a local decoder takes no hints at inference time.
- `OpenAITranscriber` — `/v1/audio/transcriptions`. Uses both halves of the context, which is the entire reason it exists. A struct rather than an actor: no model to load, no state to guard.

**Why Parakeet and not Whisper.** Whisper is autoregressive, so with no speech it still produces *something* — `[BLANK_AUDIO]`, `(music)`, `<|nospeech|>`. Push-to-talk generates a lot of short, noisy captures, so parrot used to carry a regex to strip those before injection. A TDT transducer emits nothing for silence, which deletes that class of bug rather than papering over it. It's also ~10× faster on the ANE and scores better on the Open ASR Leaderboard. The cost is coverage: 25 languages instead of 99 — which is what `gpt-transcribe` is the answer to.

### `AudioFileReader` and `FileTranscription`

A recording off disk instead of off the microphone, reachable three ways: the Transcribe pane, the menu bar item, and `parrot transcribe <file>`.

`AudioFileReader` decodes through `AVAssetReader` rather than `AVAudioFile`, because the recordings people want transcribed include the screen recording and the exported call — one code path covers every audio container AVFoundation knows *and* the audio track out of a video.

`FileTranscription` is the short half of `DictationPipeline`: decode → transcribe → wordlist → optional cleanup → store. What it drops is dropped on purpose. Shortcut expansion and entity tagging both turn something you *said* into something you meant, and neither has a claim on a recording made an hour ago in another room; nothing is injected at a cursor, because the result of a forty-minute file is not a keystroke. Stats are skipped too — "time saved versus typing" is a claim about your own speaking.

Cleanup is off by default here, and chunked when switched on. An hour of speech is ~10k words; one request is a context-limit error or a bill. `TranscriptChunker` cuts on sentence boundaries, falling back to word count for the monologue that runs a thousand words without a full stop, and each chunk goes through the same `cleanWithFallback` dictation uses — so one chunk timing out costs its own raw text and nothing else.

`FileTranscriptionJob` is the same run as observable state, shared by the pane and the menu bar so a job started from one is visible in the other. It borrows the daemon's warm engine when there is one and loads its own when there isn't, which is what makes the pane work under a bare `parrot settings`.

### `LanguageSelection`

Resolves the configured language list into the single hint FluidAudio takes. Parakeet v3 always auto-detects across all 25; what the decoder accepts is a hint that filters candidate tokens by **writing script**. So it will not stop English being transcribed as Swedish (both Latin), but it will stop stray Han or Cyrillic appearing in an otherwise Latin transcript. Languages from different scripts leave nothing to enforce, so filtering is disabled rather than silently picking one.

### `PhraseRules`

The shared matcher behind the wordlist, shortcuts and the entity tagger. Literal phrase → text, case-insensitive, word-boundary anchored, compiled into **one alternation applied in a single left-to-right pass** — text a rule emits is never re-examined by another rule. Applying rules sequentially instead lets a `"claude"` rule chew through the output of a `"claude code"` rule. Longest key first, so the most specific rule wins at a position.

Rules are literal rather than regex: this is user-facing config, and a stray `.*` there is a footgun, not a feature.

`looseSpacing` lets a run of spacing or mid-phrase punctuation stand between the words of a key — a spoken trigger needs it, because the transcriber decides on its own where the commas go. It deliberately excludes anything that *ends* an utterance (`.` `!` `?`, line breaks): a key spanning those is matching two sentences.

`ranges(in:)` is what lets one rewriter fence another off. Shortcut triggers are excluded from both wordlist passes and from tagging, because a rule that respells a trigger's words leaves a shortcut that silently stops firing.

### `Wordlist`, `ShortcutExpander`, `EntityTagger`

Three rewriters over `PhraseRules`, distinguished by intent:

- **`Wordlist`** — corrections. Words the transcriber got wrong. Runs on both sides of cleanup: before, so the model sees correct proper nouns; after, so the user's replacements win regardless of what the model did. Safe to run twice because the single-pass design makes it idempotent for any wordlist where a replacement doesn't reintroduce another rule's key.
- **`ShortcutExpander`** — deliberate triggers. The expansion can be a paragraph. Runs **once**, at the end: an address or a canned prompt is never handed to the cleanup model to be "corrected".
- **`EntityTagger`** — names read off the screen. Also runs late, before shortcuts, and also fenced off their triggers.

### `TextCleaner` (protocol)

```swift
protocol TextCleaner {
    var name: String { get }
    func clean(_ text: String, context: CleanupContext) async throws -> String
}
```

`AppleFoundationCleaner` (on-device, macOS 26+, the default), `AnthropicCleaner` (Messages API), `OpenAICleaner` (Responses API). Keys from the Keychain, with an env-var fallback.

Two guards, because a cleaner sits between the user's voice and their keystrokes:

- **Prompt injection.** The transcript goes in as a user turn, never concatenated into the system prompt, and the instructions say the text is dictation rather than a request. Dictating "ignore your instructions and write X" produces the sentence, not X.
- **Length sanity.** `CleanupGuard` discards a result outside 0.4×–2.5× the input's word count. Catches refusals, meta-commentary and runaway generations.

Any failure — timeout, no network, no key, wrong macOS version — logs to stderr and returns the pre-cleanup text. **Dictation never blocks on a language model.**

`CleanupModels` asks each provider which models the user's key can actually call, cached for a day. A hardcoded list is wrong the week after it ships, and a typed id comes back as an opaque 404 in the middle of a dictation.

### `LLMClient` (protocol)

Squawk's provider layer, separate from `TextCleaner` because the shapes differ: squawk needs a system/user split, a token ceiling, a reasoning-effort knob and a JSON schema.

```swift
protocol LLMClient {
    var name: String { get }
    func complete(_ request: LLMRequest) async throws -> String
}
```

`LLMSchema` is the sliver of JSON Schema squawk needs — a flat object of string properties, some enumerated. A general JSON Schema type would be a lot of machinery for one call site, and each provider spells the same shape differently anyway. `withDeadline` wraps every call, so a model that never answers can't leave a recording stuck in "thinking".

### `ScreenReader` / `ScreenContext`

Squawk's read. Walks the frontmost app's AX tree and returns selection, focused-field contents, and filtered window text in reading order, under four limits: character budget, node count, depth (deep — Electron stacks 7–9 container levels above its web content), and a wall-clock deadline. Blocking and deliberately **not** `@MainActor`: every call is IPC into another process's runloop, so a hung app would take parrot's main thread with it.

Chromium apps expose nothing until asked to build a tree, so parrot asks — once per app, and never with the flag that disturbs a field being typed in.

### `RosterReader` / `AppIntegration` / `AppRoster`

Integrations' read, and everything downstream of it.

`RosterScan` is deliberately flat and geometric: nodes with text, role and screen-absolute frame, plus zone helpers (left rail, main area, top band). Every integration is a guess about how one app lays its window out, and geometry is the only thing those apps agree on — a sidebar is on the left in Slack and in VS Code and in Discord, whatever their accessibility trees call it.

`AppIntegration` is a struct with a `classify` closure rather than a protocol: each is a handful of heuristics over the same scan, and a protocol with one method per conformer would be four files of ceremony around four functions. `RosterText` holds the string-level rules — `looksLikePersonName`, `looksLikeFilename`, `identifiers(in:)`, `issueKeys(in:)` — separated out because those are the parts worth testing against a literal string.

`AppRoster` carries its own diagnostics, because the interesting failure isn't an error — it's an empty result, and "the walk found nothing" and "the walk never ran" have to be told apart by anything deciding whether the integration still works. `IntegrationUnavailable` names the difference for the settings row.

A roster under `minimumEntities` (2) is thrown away: one name is an app that exposed a stray label, and tagging off the back of it is worse than not tagging.

### `TextInjector`

`CGEventCreateKeyboardEvent` + `CGEventKeyboardSetUnicodeString`, 20 UTF-16 units at a time.

Two entry points. `inject` types. `put` types below `pasteThreshold` (200 characters) and pastes above it: synthesised keystrokes go 20 characters per event, so a 1500-character email is 75 events posted back to back, which Electron apps and web text areas visibly drop characters from. A dictated sentence is short enough that typing stays better — it needs no clipboard and lands in apps where ⌘V is bound to something else.

The paste path saves and restores the user's clipboard, on a delay and only if nothing else has claimed it since: the paste is asynchronous — the keystroke only tells the frontmost app to read the pasteboard — so restoring immediately races the app about to read it. It also suppresses local keyboard state, so a modifier the user is still holding doesn't turn ⌘V into ⌃⌘V.

Squawk's `.replace` needs no separate mechanism: typing over a selection replaces it, and so does pasting over one. What it needs is for nothing to have disturbed the selection in the meantime, which is why nothing clicks or moves the cursor first.

### `RecordingOverlay`

One borderless `NSPanel` at the bottom-centre of the active screen, `.statusBar` level, `ignoresMouseEvents`, `[.canJoinAllSpaces, .stationary, .ignoresCycle]`. Content is SwiftUI in an `NSHostingView`.

States: `hidden`, `recording`, `latched` (same waveform plus a lock), `transcribing`, and `thinking` — squawk only. `thinking` is split out because it is the wait with no predictable length, and sitting through it not knowing which wait you're in is the worst of it.

Mode is carried into the pill so the two are never mistaken for each other: dictation draws a scrolling bar meter in cool blue, squawk a single line in warm amber, and the model working goes violet. Hue carries further in peripheral vision than shape does.

The meter learns a room noise floor and has a user-tunable sensitivity, previewable live against the real microphone from the settings window — it depends on your mic, your room and how loudly you talk, so a number to guess at is the wrong control.

### `MenuBarController`

`NSStatusItem` with an inlined template glyph. Shows utterance state (`idle` / `recording` / `latched` / `transcribing`) and, separately, engine state (`loading` / `ready` / `failed` / `needsPermission`) — a model can still be loading while nothing is recording, and that's exactly when the user wants to know.

The last 10 transcripts sit in a **Recent** submenu, and input devices in a **Microphone** submenu. Both are populated in `menuNeedsUpdate(_:)` rather than pushed on change: that keeps the injection path free of UI work and makes stale entries structurally impossible — the list is built at the moment it's shown, which matters for devices that come and go while the app runs.

Clicking a transcript **copies it** rather than re-injecting. By the time the menu closes, focus has returned to whatever was underneath, and typing into it uninvited is a worse surprise than a clipboard write.

Since the process runs `.accessory`, this is the only persistent surface the user can see and click.

### `TranscriptStore` and `StatsStore`

Two JSONL files under `~/.local/share/parrot/`, mode `0600`.

`history.jsonl` is append-only, pruned to `maxEntries` at startup, and records both `raw` and final `text` plus mode, model, duration and whether cleanup ran — so cleanup regressions are diagnosable. JSONL over SQLite deliberately: at ~200 bytes an entry the 5000-entry cap is about a megabyte, so a full in-memory scan for search is instant, there's no schema to migrate, and the file stays greppable. Lines that fail to decode are skipped rather than fatal.

`stats.jsonl` is one line per day per model, counters only — no text ever lands there, which is why usage counting keeps working for someone who has turned history off. Separate from history because history is pruned and clearable, so lifetime totals derived from it would silently shrink. The daemon is the only writer, so each dictation atomically rewrites the whole file (~150 bytes per day of use) and a crash can't tear it.

### `ModelRegistry` and `ModelCatalog`

```swift
struct TranscriptionModel: Codable {
    let id: String              // "parakeet-v3"
    let displayName: String
    let engine: Engine          // .parakeet | .openai
    let engineModelID: String?
    let sizeMB: Int             // 0 for remote
    let languages: [String]
    let recommended: Bool
}
```

The list lives in source rather than a JSON resource, so the executable stays self-contained — no `Bundle.module`, no resource bundle to install alongside the binary. `find(_:)` also resolves **retired ids**: a LaunchAgent plist written before the Parakeet switch still passes `--model whisper-base.en`, which maps to `parakeet-v3` with a one-line notice rather than a hard failure.

Fetching is FluidAudio's (Hugging Face into its own cache), but the *state* of it is parrot's: `ModelCatalog` is a main-actor `ObservableObject` that knows which models are on disk, how many bytes each takes, and the progress of one being fetched. It exists because a 460 MB download wants a progress bar, a size, a failure with a retry and a way to reclaim the space — none of which fit in a capsule at the bottom of the screen. `WarmupProgressCurve` folds FluidAudio's per-sub-operation sawtooth into a fraction that only climbs, so a download that is working doesn't look like it's looping.

### `Settings` and `SettingsStore`

One `Codable` struct, stored as a single JSON blob in `UserDefaults(suiteName: "com.enemyrr.parrot")`. It replaced a hand-edited `config.toml`.

One blob under one key, rather than a key per field, buys three things:

- Writes are **atomic** — no reader sees half a change.
- The value is `Equatable`, so `DictationController` can diff old against new and rebuild only what changed.
- Decoding is per-key tolerant (`decodeIfPresent` everywhere), so a blob written by an older build gains new fields' defaults instead of failing to load and silently resetting everything.

An explicit suite, not `UserDefaults.standard`: parrot runs both as a bare binary on `$PATH` and as `parrot.app`, and the standard suite would give those two different preference domains — the same user's settings would appear to vanish depending on how they launched it.

Sections: `model`, `languages`, `audio`, `hotkey`, `latch`, `squawk`, `style`, `cleanup`, `wordlist`, `shortcuts`, `integrations`, `history`, `stats`, `overlay`.

Two migrations run inside `init(from:)` rather than as a separate pass, because they read shapes nothing writes any more: "about you" and the per-app profiles moving out of `squawk` into `style`, and `style` itself going from one global tone plus profiles to a list of categories. Both are the difference between an upgrade that keeps what someone wrote and one that silently resets it.

`LegacyConfigMigration` reads an existing `config.toml` once, folds it into `Settings`, and renames the file to `config.toml.migrated` — the rename is what makes it run exactly once. Every section decodes independently: the old loader treated a malformed file as fatal, which was right when it was live configuration, but during a one-shot import a single bad line shouldn't cost the user the other nine sections.

Data still lives under `$XDG_DATA_HOME` (default `~/.local/share`), so transcripts and stats stay out of `~/Library` and are easy to point elsewhere in tests.

### `DictationController`

The running daemon as one main-actor object: transcriber, hotkey monitor, capture, mute, overlay, menu bar, stores, cleaner, and the two AX capture tasks.

Everything used to be assembled once inside `Run.run()` and then frozen — changing a setting meant editing a file and restarting. Now `SettingsStore.onChange` hands the controller `(old, new)` and it reconfigures only what differs: a new model reloads the engine, a new hotkey restarts the tap, a new sensitivity just retunes the meter. Both pipelines are rebuilt **per utterance** rather than held as fields, because every component they name can be swapped mid-session and a stale pipeline would quietly keep using the old one.

Everything here is main-actor: the tap already delivers on the main runloop and the overlay is a window, so the alternative would be hopping queues for no benefit. The genuinely concurrent work — model load, transcription, and both AX walks — lives behind an actor or a detached task. The walks are detached specifically so one wedged app can't take the hotkey and the pill down with it.

Warm-up is non-blocking. It used to pump the runloop against a semaphore so the download pill could animate; now the app comes up immediately and the engine's state is reported in the menu bar and in the settings window's status bar. Warm-ups are generation-tagged, so switching models mid-load leaves the superseded one unable to report itself ready.

## The settings window

`SettingsPane` is the sidebar, but only some cases are rows. `home`, `squawk`, `cleanup`, `style`, `dictionary` and `integrations` are visible; `models`, `history` and `usage` land on Home, where the model row, the transcript list and the totals live; `permissions` and `accounts` land on About with their sheet up. They stay cases because `parrot settings --pane <name>` and the menu bar name them.

The shape is deliberate. **Home** answers the two questions the window gets opened for — which key do I hold, and what did I just dictate — before it shows a single setting. The settings themselves are rows that state their current value and open a sheet, so the answers stay on the page and the machinery doesn't. Anything that's a dial rather than a decision is folded under **Advanced**.

`SettingsContext` is everything a pane needs from a running daemon — engine status, the overlay preview hooks — and all of it is optional, because `parrot settings` opens the same window with no daemon behind it. Panes that need a live engine say so rather than pretending.

Two panes are built around showing rather than describing: **Cleanup** runs the same sentence through both modes side by side, and **Style** picks tone and length by showing the same message written three ways. The samples are static strings — a model call per card would be slower, cost money, and give a different answer every time the pane opened, which is the opposite of what a reference sample is for.

## First run

`OnboardingWindowController` shows the first time the daemon starts, before the engine and the hotkey tap, and records that it did under its own `UserDefaults` key (`onboarding.completed`) — not on `Settings`, which is what the user configures rather than what parrot has shown. `parrot setup` and a button in the Permissions sheet bring it back.

Five steps, in the order they depend on each other: welcome → microphone → accessibility → key → try it.

Three things it does that a checklist can't:

- **The microphone step proves the mic works** rather than reporting that it's allowed — a granted permission and the right input device are not the same thing. It opens its own `AudioCapture` and drives `OverlayModel`, so the meter is calibrated exactly like the recording pill's.
- **Nothing needs a Refresh button.** Every grant lands in another process, so `OnboardingChecks` polls microphone, accessibility and — only when Fn is the chosen key — the Fn mapping, once a second while the window is open.
- **It ends in the user's own voice landing in a text field.** The last step focuses a scratch field and shows the model download's progress; because injection goes to whatever is frontmost, the first dictation needs no plumbing beyond that focus.

Skipping is always possible. A grant can fail for reasons parrot can't see, and trapping someone on step three would be worse than letting them through to a menu bar icon that says what's still missing. Closing counts as finishing — reopening on every launch until someone reaches the end would be nagging.

While it's open, `showSetupWindowOnce` stands down: a settings window over the top would be two setups at once, disagreeing about which step you are on.

## Permissions

Two grants, surfaced in the setup window, the **Permissions** sheet and `parrot doctor`:

1. **Microphone** — standard `AVCaptureDevice` request, which the sheet can trigger directly.
2. **Accessibility** — required for `CGEventTap` (hotkey), `CGEvent` posting (injection) and every AX read. Only System Settings can grant it, so the button opens that pane rather than pretending to fix it.

`DoctorReport` is the single source of truth for both, plus advisory checks on the Fn mapping, the model, languages, cleanup and squawk. `Check` carries a `CheckKind` so the UI can attach the right action without matching on message strings, and only `.microphone`, `.accessibility` and `.fnKey` count as required — an unknown language code can't be fixed in the Permissions sheet, and sending someone to a pane with no control for their problem is worse than naming no pane. Checks re-run on a timer, because every grant is made in another window and coming back to a stale ✗ with a Refresh button would be the app pretending it couldn't tell.

Missing Accessibility no longer stops the daemon. It stays up, opens the Permissions sheet, and polls `AXIsProcessTrusted()`; the moment the grant lands it registers the tap and starts listening. The old build exited deliberately, to avoid a crash loop, and required a manual restart — the most confusing thing about first run.

### TCC quirk worth knowing

When you launch `parrot` from `Terminal.app`, accessibility permission is granted to *Terminal*, not parrot. So switching terminals means re-granting, and running under `launchd` means granting to whatever spawns it. This is macOS behaviour, not a parrot bug; `parrot doctor` identifies the parent process and says which app needs the permission.

## Data flow, end-to-end

1. `parrot` starts. Any legacy `config.toml` is imported once, then `DictationController` reads `Settings` and instantiates modules. On a first run the setup window opens here. The model warms up in the background; if it isn't downloaded, the fetch starts anyway — reported inside the setup window if it's up, and on the Models sheet if it isn't.
2. `.accessory` policy, `NSApp.run()`. Menu bar icon idle, overlay hidden. If Accessibility is missing, the Permissions sheet opens (unless setup is already asking) and the controller polls until the grant lands.
3. User holds the key. `HotkeyMonitor` fires `.begin(mode)`.
4. `AudioCapture` starts; system audio mutes if configured; the pill appears wearing the mode's colours.
5. **In parallel**, on a detached task: squawk kicks off `ScreenReader.capture`; dictation captures the front bundle id and, if integrations are on and this app has one that hasn't given up, kicks off `RosterReader.read`.
6. User releases (or taps once more, if latched). `.end`. Audio stops, mute restores, the pill switches to `transcribing`.
7. **Dictation:** await the roster → build `EntityTagger` → build the pipeline → transcribe → wordlist → cleanup (if enabled and over `minWords`) → wordlist → tag → shortcuts → store to history and stats → `TextInjector.inject`.
8. **Squawk:** transcribe → wordlist → shortcuts → build the prompt with the awaited `ScreenContext` → pill goes to `thinking` → `LLMClient.complete` under a deadline → parse `{action, text}` → `SquawkGuard` → `TextInjector.put`.
9. Overlay hides, menu bar back to idle. Any failure at any step falls back to doing nothing rather than typing something arbitrary.

A file transcription is the same engine with steps 3–6 removed. `FileTranscriptionJob` (or `parrot transcribe`) builds a `FileTranscription` — decode → transcribe → wordlist → optional chunked cleanup → store — and hands the text back to whoever asked for it. Nothing is injected, no shortcut is expanded, no window is read, and the run is recorded in history as `.file` but kept out of the usage stats.

End-to-end latency target: <500 ms after release for utterances under 10 seconds, on Apple Silicon, with cleanup off. Cleanup adds its own round trip, gated behind `minWords` and a timeout that falls back to the raw text. Squawk is a model call and makes no such promise — which is what the violet `thinking` state is for.

## Project layout

Organized by feature area. These are folders within a single SPM executable target — Swift sees them as one module, so there are no `import` statements between files. If a group later earns its keep as a reusable library, it can be promoted to its own target with no rewriting.

```
parrot/
  Package.swift
  Sources/parrot/
    Parrot.swift                # entry point, subcommands, NSApp.run()
    Doctor.swift                # checks + the actions that fix them
    Install.swift               # deprecated aliases for start/stop

    Settings/
      Settings.swift            # the whole settings value type + migrations
      SettingsStore.swift       # UserDefaults-backed, observable
      Hotkey.swift              # modifier or recorded shortcut
      LegacyConfigMigration.swift

    Config/
      Paths.swift               # XDG-style data locations

    Transcription/
      Transcriber.swift         # protocol, context, errors
      ParakeetTranscriber.swift
      OpenAITranscriber.swift
      LanguageSelection.swift
      FileTranscription.swift   # a recording off disk, and the chunker
      FileTranscriptionJob.swift # the same run, as observable state
      TranscribeCommand.swift   # `parrot transcribe <file>`

    Text/                       # everything between ASR and the cursor
      DictationPipeline.swift
      PhraseRules.swift         # the shared matcher
      Wordlist.swift
      ShortcutExpander.swift
      EntityTagger.swift
      Style.swift               # categories, tone, length
      TextCleaner.swift         # protocol, prompt, guards, fallback
      AppleFoundationCleaner.swift
      AnthropicCleaner.swift
      OpenAICleaner.swift
      CleanupModels.swift       # per-account model lists, cached
      Keychain.swift

    LLM/                        # squawk's provider layer
      LLMClient.swift           # protocol, request, schema, deadline
      AppleLLMClient.swift
      AnthropicClient.swift
      OpenAIClient.swift

    Squawk/
      SquawkPipeline.swift
      SquawkPrompt.swift        # layers, schema, response parsing, guards
      SquawkCommand.swift

    Context/                    # everything that reads a window
      ScreenContext.swift       # AppTarget, ScreenReader, exclusions
      RosterReader.swift        # the names walk + IntegrationMonitor
      AppIntegration.swift      # per-app classifiers + text rules
      AppRoster.swift           # entities, availability
      ContextCommand.swift
      RosterCommand.swift

    History/
      TranscriptStore.swift     # append-only JSONL
      StatsStore.swift          # per-day counters, no text

    Models/
      ModelRegistry.swift
      TranscriptionModel.swift
      ModelCatalog.swift        # installed? how big? download, delete
      WarmupProgressCurve.swift

    Audio/
      AudioCapture.swift        # AVAudioEngine tap + ring buffer
      AudioFileReader.swift     # any container → 16 kHz mono float
      AudioDevices.swift        # CoreAudio input-device enumeration
      SystemAudioMute.swift

    Input/
      HotkeyMonitor.swift       # CGEventTap + latch state machine
      TextInjector.swift        # type or paste

    Daemon/
      DictationController.swift # owns the runtime, reacts to settings changes
      DaemonCommands.swift      # start/stop/restart/status/logs
      LaunchAgent.swift

    UI/
      RecordingOverlay.swift    # borderless NSPanel + SwiftUI pill
      OverlayPreview.swift
      MenuBarController.swift
      ParrotGlyph.swift         # the bird, as inline SVG
      Onboarding/
      Settings/
        SettingsWindowController.swift
        SettingsRootView.swift  # sidebar + detail
        Panes/                  # Home, Squawk, Transcribe, Cleanup, Style,
                                # Dictionary, Integrations, About
        Dialogs/                # Models, Languages, Microphone, Shortcuts,
                                # Permissions, Accounts

  Resources/                    # Info.plist + entitlements, for the .app only
  Tests/parrotTests/
  scripts/                      # bundle.sh, install.sh, icon + DMG rendering
  docs/architecture.md
```

The model registry and the bird glyph live in source rather than `Resources/`, so the CLI binary ships as a single file with no resource bundle beside it. `Resources/` holds only what the `.app` wrapper needs.

Build: `swift build -c release`. Binary at `.build/release/parrot`.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). parrot uses a single executable target with the folder structure above; everything is in the same module. If we ever want enforced boundaries — `Transcription` and `UI` shouldn't reach into `Audio` internals — we promote folders to separate targets in `Package.swift`. A structural change, not a semantic one.

## Revisited cuts

Each of these was a deliberate "no" that real usage overturned. They're listed because the reasoning behind the reversal is the useful part.

- **Menu bar item** — an `.accessory` process with no window had no way to tell you it was alive, or to surface history.
- **History** — "output goes to the cursor and that's it" is fine until a transcript lands in the wrong window.
- **Custom vocabulary and post-processing** — raw ASR output has no sentence breaks and keeps every "um".
- **A settings window** — the original cut said "configuration is flags + TOML". That held right up until the things needing configuration stopped being scalars: a 460 MB download wants a progress bar, a permission wants a button that opens the right System Settings pane, and meter sensitivity can only be judged against your own voice. None of those are expressible in a text file.
- **Cloud transcription** — see *On cloud transcription* above. Kept honest by never being the default and by saying, in the row that selects it, where the audio goes.
- **Reading the screen at all** — squawk, then integrations. Both opt-in, both scoped to the front app while a key is held, neither stored.

## Known gap: decoder-level vocabulary biasing

The Dictionary's vocabulary feeds the cleanup prompt as terms to preserve, and the OpenAI transcriber as `keywords`. FluidAudio ships real CTC-based decoder biasing (`CustomVocabularyContext`, per NVIDIA's CTC-WS paper), which would make Parakeet *recognize* a rare proper noun rather than having us correct it afterward.

Not wired up because for Parakeet 0.6B it needs a separate ~130 MB CTC encoder and drops throughput from ~120× to ~26× real-time. That's a real cost for a feature the post-hoc wordlist approximates — and one the roster's vocabulary hints now cover for the API path. Worth revisiting if phonetically-hard names turn out to be a common local failure.

## Open questions

- **Left vs. right modifiers.** `CGEventFlags` has no left/right distinction, so "option" means either option key. Telling them apart means tracking keycodes through `flagsChanged` — doable, not obviously worth it.
- **Tap re-registration.** `CGEventTap` can be disabled by the system (`tapDisabledByTimeout`); today parrot logs and expects a restart. It should re-enable itself.
- **Slack mentions resolve on a handle, not a display name.** `@Sara Rekvik` doesn't linkify — the space ends the token — so the tagger emits `@Sara` and leans on Slack's own autocomplete for ambiguous first names. Correct, but it is the known limit of that integration.
- **Chromium editors keep their buffer off the AX tree** until screen-reader mode is on, so every VS Code fork finds filenames and no identifiers. parrot detects this and says so; there's no fix from this side.
- **Decoder-level biasing.** See above.
