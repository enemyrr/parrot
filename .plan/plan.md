# Parrot — Implementation Plan

A minimal macOS dictation daemon. CLI-launched, push-to-talk on Fn hold (or double-tap for hands-free), on-device transcription via Parakeet, text injected at cursor.

See [../docs/architecture.md](../docs/architecture.md) for the full design.

> **Note:** milestones M0–M6 below are kept as written at the time, as a record of how the thing was actually built. M4 shipped on WhisperKit; M7 replaced it with Parakeet. Read M7 onward for the current shape.

## Approach

Phased, each milestone produces something testable end-to-end. Linear order — each phase de-risks the next. M4 (transcription) is the load-bearing de-risk: if ANE latency is insufficient there, the rest of the plan is moot.

## Milestones

### M0 — Project skeleton

Goal: builds, runs, exits cleanly. No behavior.

- `Package.swift` — SPM exec target, `swift-argument-parser` dep
- `Sources/parrot/main.swift` — argument parsing, `setActivationPolicy(.accessory)`, `NSApp.run()`, SIGINT handler
- Empty subfolder stubs (`Audio/`, `Input/`, `Transcription/`, `Models/`, `UI/`)

**Test:** `swift run parrot` starts and stops cleanly. `parrot --help` works. No dock icon, no menubar.

### M1 — Doctor + permissions surface

Goal: actionable feedback on permission state before anything tries to use the perms.

- `Doctor.swift` — checks: microphone (`AVCaptureDevice.authorizationStatus`), accessibility (`AXIsProcessTrusted`), Fn-key system mapping
- `parrot doctor` subcommand prints status + remediation steps

**Test:** Run before granting perms — see red Xs and instructions. Grant perms, re-run — see green checks.

### M2 — Hotkey monitor (Fn hold)

Goal: clean `.pressed` / `.released` events for Fn.

- `HotkeyMonitor.swift` — `CGEventTap` on `flagsChanged`, detect `kCGEventFlagMaskSecondaryFn` edges
- Wire into `main.swift` — log "fn down" / "fn up" to stderr

**Test:** Hold Fn, see "fn down". Release, see "fn up". No double-fires; no missed releases when switching apps mid-hold.

### M3 — Audio capture

Goal: clean PCM buffer for the duration of the hold.

- `AudioCapture.swift` — `AVAudioEngine` input tap, 16 kHz mono Float32, ring buffer
- Start on `.pressed`, stop on `.released`, log buffer length + RMS to stderr
- (Optional) write captured PCM to `/tmp/parrot-last.wav` for QuickTime inspection

**Test:** Hold Fn, talk, release. stderr shows `captured 3.2s, RMS 0.08`. WAV plays back as clean speech.

### M4 — WhisperKit transcription (de-risk milestone)

Goal: end-to-end audio → text in the terminal. Validates that ANE latency hits target.

- Add WhisperKit dep
- `TranscriptionModel.swift` + `ModelRegistry.swift` + `Resources/models.json` (3 entries)
- `ModelDownloader.swift` with stderr progress
- `Transcriber.swift` protocol + `WhisperKitTranscriber.swift`
- `parrot models list` and `parrot models download <id>`
- Wire end-to-end: `.released` → transcribe → log to stderr

**Test:** `parrot models download whisper-base.en`. Hold Fn, say "hello world", release — transcript on stderr. Measure latency for 5s and 10s utterances. Target: <500ms post-release for <10s clips.

### M5 — Text injection

Goal: the actual product loop.

- `TextInjector.swift` — `CGEvent` + `CGEventKeyboardSetUnicodeString`
- Replace stderr log with cursor injection

**Test:** TextEdit, Slack, Safari address bar, VS Code, fish prompt — text appears at cursor in each.

### M6 — Recording overlay

Goal: visual feedback that mic is hot.

- `RecordingOverlay.swift` — borderless `NSWindow`, `.statusBar` level, `ignoresMouseEvents`, `NSHostingView` + SwiftUI pill (pulsing dot + "listening")
- States: hidden → recording → transcribing → hidden, driven by hotkey + transcription lifecycle
- (Optional) mic-level animation from `AudioCapture`

**Test:** Pill appears bottom-center on Fn down, animates, switches to spinner on release, disappears after injection. Clicks pass through to the app underneath.

### M7 — Parakeet engine + Config TOML ✅ done

Goal: second engine, persistent config.

Landed with a larger scope than planned — Parakeet **replaced** WhisperKit rather than joining it, because a TDT transducer emits nothing for silence and that deleted the whole class of `[BLANK_AUDIO]` bugs push-to-talk kept hitting.

- `ParakeetTranscriber.swift` (FluidAudio) — `parakeet-v3` (25 languages, default) and `parakeet-v2` (English)
- WhisperKit dependency, `WhisperKitTranscriber.swift`, and the `sanitize()` bracket-token hack all removed; retired model ids alias to `parakeet-v3`
- `Config.swift` — TOML loader at `~/.config/parrot/config.toml`, CLI flags override
- `--model`, `--hotkey`, `--no-overlay` flags

### M7.5 — Dictation quality ✅ done

Not in the original plan. Four features that turned raw ASR output into something you'd actually paste into a document:

- **Hands-free mode** — double-tap the hotkey to latch; `HotkeyMonitor` became a state machine emitting `.begin`/`.latched`/`.end`/`.cancelled`, with Escape to discard and a `max_seconds` backstop
- **Wordlist** — literal find/replace + vocabulary terms, single-pass so rules can't cascade into each other
- **Cleanup** — opt-in punctuation/filler-word pass; Apple `FoundationModels` on-device by default, Anthropic opt-in, always falling back to the raw transcript on failure
- **History** — append-only JSONL, `parrot history [search|clear]`, last 10 in the menu bar

This walked back three of the original non-goals (menu bar, history, post-processing). See `docs/architecture.md` for the reasoning.

### M8 — Polish

Goal: shippable to a second user.

- Resumable downloads, size validation
- Error UX: missing model, perm denied, tap registration failure
- Release build, install instructions in README
- Decide: code signing for stable accessibility grant

**Test:** Fresh-clone simulation — clone, build, doctor, download, dictate. Time-to-first-transcript < 5 minutes.

## Commit boundaries

One milestone ≈ one commit (or a small linear series). Don't fold M5 into M4 — keeping the audio→text loop separate from injection makes regressions bisectable.

## Open questions (deferred)

- ~~Parakeet via FluidAudio vs. direct CoreML~~ — FluidAudio, decided at M7. It handles model download, chunking, and long-form audio; hand-rolling CoreML would mean reimplementing all three.
- ~~Bundle a model for first-run UX, or always download~~ — always download. FluidAudio caches on first use.
- Code signing for stable TCC grants — decide at M8
- Decoder-level vocabulary biasing (FluidAudio CTC-WS) — costs ~130 MB and ~4× throughput; revisit if proper nouns prove to be a real failure mode
