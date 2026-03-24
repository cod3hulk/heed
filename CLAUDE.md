# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
make build     # swift build -c release → app bundle → codesign
make clean     # swift package clean + rm build/
make install   # build + rsync to /Applications/
```

## Architecture

Heed is a macOS menubar-only app (LSUIElement=true) that records meetings, transcribes locally via Parakeet, and processes transcripts through LLMs. Pure Swift, SPM-based, macOS 15+.

**Entry point:** `HeedApp.swift` — `@main AppDelegate` with explicit `static func main()` bootstrapping `NSApplication.shared`. This is required because SPM executable targets don't auto-bootstrap the AppKit lifecycle.

**Key constraint — Swift 6 concurrency:** Package.swift uses `.swiftLanguageMode(.v5)` because AVAudioEngine's `installTap` callback runs on a realtime audio thread and Swift 6 runtime traps on actor isolation boundary crossings. The tap closure must ONLY use raw C pointers (`floatChannelData`) and value types — no `[weak self]` capturing `@MainActor` classes, no `AVAudioPCMBuffer` passed to functions, no static methods on `@MainActor` types.

**Audio pipeline:** `AudioCaptureService` captures mic via AVAudioEngine at native sample rate (typically 48kHz), mixes to mono in the tap callback, collects samples in a thread-safe `AudioSampleCollector` (uses `OSAllocatedUnfairLock`), then resamples to 16kHz on the main thread after recording stops. `SystemAudioCapture` captures system audio via ScreenCaptureKit (`SCStream`, `capturesAudio = true`, `excludesCurrentProcessAudio = true`). Both streams are resampled to 16kHz and mixed (60% mic / 40% system) before transcription.

**Global shortcuts:** `GlobalShortcutManager` uses Carbon `RegisterEventHotKey` (not NSEvent monitors, which require Input Monitoring permission on modern macOS).

**Overlay:** `OverlayWindow` manages a floating `NSPanel` with SwiftUI content via `NSHostingView`. Waveform bars animate in-place based on live audio levels (not scrolling). 60fps timer polls `AudioCaptureService.currentLevel`.

## macOS Permission Gotcha

macOS kills the app process when granting new permissions (mic, screen recording). Permissions must be requested upfront at launch in `requestPermissionsUpfront()`, not when the user first tries to record.

## Remaining Work

### State Machine
A `RecorderStateMachine` needs to drive the full lifecycle and publish state changes to the overlay UI:

```
.idle → .recording → .transcribing → .actionSelection → .processing → .done(result) → .idle
                                                                      ↘ .error
```

- `.actionSelection` — user presses `⌘1` (Summarize) or `⌘2` (Meeting Feedback); overlay shows both options
- `.processing` — transcript + selected prompt sent to configured LLM provider
- `.done(result)` — result displayed in overlay, copyable

### LLM Integration
`LLMService` protocol with three providers, user-configurable via Settings:

| Provider | Mechanism | Config |
|---|---|---|
| **Ollama** | HTTP POST `/api/generate` | endpoint URL + model name |
| **Claude CLI** | shell out to `claude` binary, pipe transcript via stdin | path to binary |
| **Gemini CLI** | shell out to `gemini` binary, pipe transcript via stdin | path to binary |

Both CLI providers: `echo "<transcript>" | claude -p "<prompt>"` style invocation.

### Post-Transcription Prompts
Two built-in actions with user-customizable prompt text (stored in config):
- **Summarize** (`⌘1`) — concise bullet-point summary of the meeting
- **Meeting Feedback** (`⌘2`) — action items, decisions, sentiment, follow-ups

### Settings Window
SwiftUI sheet opened from menubar → Settings…:
- LLM provider picker + model/endpoint fields
- Custom prompt text areas (summary & feedback)
- Global shortcut recorder (default `⇧⌘R`)

### Config Persistence
`ConfigManager` backed by JSON in `~/Library/Application Support/Heed/config.json`. Expose via `@Published` properties for SwiftUI bindings.
