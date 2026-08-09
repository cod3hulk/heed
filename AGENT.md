# AGENT.md

This file provides guidance to AI coding agents when working with code in this repository.

## Build Commands

```bash
make build     # swift build -c release → app bundle → codesign
make test      # run unit tests (no Xcode required)
make clean     # swift package clean + rm build/
make install   # build + rsync to /Applications/
```

## Architecture

Heed is a macOS menubar-only app (LSUIElement=true) that records meetings, transcribes locally via Parakeet, and processes transcripts through LLMs. Pure Swift, SPM-based, macOS 15+.

**Entry point:** `HeedApp.swift` — `@main AppDelegate` with explicit `static func main()` bootstrapping `NSApplication.shared`. This is required because SPM executable targets don't auto-bootstrap the AppKit lifecycle.

**Key constraint — Swift 6 concurrency:** Package.swift uses `.swiftLanguageMode(.v5)` because AVAudioEngine's `installTap` callback runs on a realtime audio thread and Swift 6 runtime traps on actor isolation boundary crossings. The tap closure must ONLY use raw C pointers (`floatChannelData`) and value types — no `[weak self]` capturing `@MainActor` classes, no `AVAudioPCMBuffer` passed to functions, no static methods on `@MainActor` types.

**HeedCore library:** Shared audio utilities live in `Sources/HeedCore/` — `AudioUtilities` (resampling, mixing) and `AudioSampleCollector`. Both the app and tests depend on this target.

**Audio pipeline:** `AudioCaptureService` captures mic via AVAudioEngine at native sample rate (typically 48kHz), mixes to mono in the tap callback, collects samples in a thread-safe `AudioSampleCollector` (uses `OSAllocatedUnfairLock`), then resamples to 16kHz on the main thread after recording stops. `SystemAudioCapture` captures system audio via ScreenCaptureKit (`SCStream`, `capturesAudio = true`, `excludesCurrentProcessAudio = true`). Both streams are resampled to 16kHz internally and mixed (60% mic / 40% system) before transcription. Resampling happens exactly once per stream — callers receive 16kHz samples directly from `stopRecording()` / `stopCapture()`.

**Global shortcuts:** `GlobalShortcutManager` uses Carbon `RegisterEventHotKey` (not NSEvent monitors, which require Input Monitoring permission on modern macOS).

**Overlay:** `OverlayWindow` manages a floating `NSPanel` with SwiftUI content via `NSHostingView`. Waveform bars animate in-place based on live audio levels (not scrolling). 60fps timer polls `AudioCaptureService.currentLevel`.

**LLM dispatch:** Lives inline in `HeedApp.swift` as `runLLM` / `runClaudeCLI` / `runOllama` (no `LLMService` protocol abstraction). CLI providers run via `zsh -l` so they inherit the user's environment. The recording lifecycle is also driven directly from `HeedApp.swift` — there is no `RecorderStateMachine` type.

**Settings:** `SettingsWindow` is an `NSWindowController` hosting a SwiftUI view with four tabs — General, Key Bindings, LLM, Prompts. The General tab uses `LoginItemManager` (a thin `SMAppService.mainApp` wrapper) for the Launch at Login toggle.

**Config persistence:** `ConfigManager` is a `@MainActor` singleton backed by `UserDefaults` (not a JSON file), exposing `@Published` properties for SwiftUI bindings. `save()` is called explicitly from the settings UI.

## Testing

Run `make test` before committing any changes to audio pipeline code. Tests live in `Tests/HeedTests/main.swift` as a standalone executable (no XCTest/Xcode dependency).

When modifying audio code, consider whether new tests are needed — especially for:
- Resampling logic (sample counts, signal integrity, new sample rates)
- Audio mixing (ratios, clamping, edge cases with mismatched lengths)
- Sample collector thread safety and drain/reset semantics

Tests should be deterministic and fast (no hardware or network dependencies).

## macOS Permission Gotcha

macOS kills the app process when granting new permissions (mic, screen recording). Permissions must be requested upfront at launch in `requestPermissionsUpfront()`, not when the user first tries to record.
