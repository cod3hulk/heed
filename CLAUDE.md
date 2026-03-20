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

**Audio pipeline:** `AudioCaptureService` captures mic via AVAudioEngine at native sample rate (typically 48kHz), mixes to mono in the tap callback, collects samples in a thread-safe `AudioSampleCollector` (uses `OSAllocatedUnfairLock`), then resamples to 16kHz on the main thread after recording stops.

**Global shortcuts:** `GlobalShortcutManager` uses Carbon `RegisterEventHotKey` (not NSEvent monitors, which require Input Monitoring permission on modern macOS).

**Overlay:** `OverlayWindow` manages a floating `NSPanel` with SwiftUI content via `NSHostingView`. Waveform bars animate in-place based on live audio levels (not scrolling). 60fps timer polls `AudioCaptureService.currentLevel`.

## macOS Permission Gotcha

macOS kills the app process when granting new permissions (mic, screen recording). Permissions must be requested upfront at launch in `requestPermissionsUpfront()`, not when the user first tries to record.

## Project Spec

Full requirements are in `PROJECT_BRIEF.md`. Remaining unimplemented: system audio capture (ScreenCaptureKit), transcription (Core ML Parakeet), LLM integration (Ollama/Claude CLI/Gemini CLI), state machine, settings window, config persistence.
