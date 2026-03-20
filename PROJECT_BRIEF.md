# Heed — Project Brief

## Overview

A native macOS menubar utility that records meetings (system audio + microphone), transcribes them locally, and processes the transcript through an LLM for summaries or meeting feedback. Fully offline transcription — no cloud, no subscription, no data leaving the machine.
The project name Heed is coming from the english verb "to heed"

## Context regarding the project name
1. Heed
Why it wins: It is the most "system-native" sounding name.
    The Vibe: It sounds like a built-in macOS feature (similar to Focus or Wallet).
    The Function: "To heed" means to pay close attention. It perfectly captures the app's behavior: it sits silently in the menubar, "heeding" the conversation so you don't have to take manual notes.
    The UI Fit: "Heed is recording..." or "Heed: Summary Ready" looks incredibly clean in a small floating pill overlay.

## Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | **Swift** | Pure Swift, no Rust/JS |
| UI framework | **SwiftUI** | Settings window, overlay |
| Window management | **AppKit** (`NSPanel`, `NSStatusItem`) | Floating overlay, menubar icon |
| System audio capture | **ScreenCaptureKit** | Apple framework, macOS 13+ |
| Microphone capture | **AVAudioEngine** | Apple framework |
| Audio resampling | **AVAudioConverter** / `vDSP` (Accelerate) | 48 kHz stereo → 16 kHz mono |
| Transcription | **Core ML** (preferred) or **ONNX Runtime Swift** (fallback) | Parakeet TDT 0.6B V3 int8 model |
| LLM integration | **Ollama** (HTTP API) / **Claude CLI** / **Gemini CLI** | User-configurable provider |
| Global shortcuts | **CGEvent tap** or `MASShortcut` | System-wide hotkeys |
| Config persistence | Disk-backed (e.g. `UserDefaults` or JSON in app support dir) | Edited via in-app Settings window |

## Functionality

### Recording
- **Global shortcut** (default `⇧⌘R`) toggles recording on/off
- Captures **system audio** (ScreenCaptureKit) and **microphone** (AVAudioEngine) simultaneously
- Mixes both sources into a single audio stream
- Falls back to mic-only if system audio isn't available within 500 ms

### Transcription
- On stop, audio is resampled to 16 kHz mono
- Chunked into ~90-second segments (model input limit)
- Transcribed locally via Parakeet TDT 0.6B V3 (Core ML or ONNX Runtime)
- Supports 25 languages (English, German, French, Spanish, etc.)
- First run triggers a one-time model download (~478 MB)

### Post-Transcription Actions
After transcription completes, user selects an action via keyboard shortcut:

| Action | Shortcut | Description |
|--------|----------|-------------|
| **Summarize** | `⌘1` | Sends transcript + summary prompt to configured LLM |
| **Meeting feedback** | `⌘2` | Sends transcript + feedback prompt to configured LLM |

Both prompts are user-customizable in Settings.

### LLM Providers
- **Ollama** — local HTTP API (`/api/generate`), user configures endpoint + model
- **Claude CLI** — shells out to `claude` CLI, pipes transcript via stdin
- **Gemini CLI** — shells out to `gemini` CLI, pipes transcript via stdin

### Menubar & UI

```
┌─────────────────────┐
│ ● Meeting Recorder  │  ← NSStatusItem in menubar
├─────────────────────┤
│ Start Recording ⇧⌘R │
│ ─────────────────── │
│ Settings...         │
│ Quit                │
└─────────────────────┘
```

- **Floating overlay** (`NSPanel`, always-on-top) — small pill showing current state: idle → recording → transcribing → action selection → result
- **Settings window** — opened from menubar context menu, with sections for:
  - LLM provider picker + model name + Ollama endpoint
  - Custom prompt text areas (summary & feedback)
  - Keyboard shortcut recorders

## Architecture

```
                    NSStatusItem (menubar)
                         │
              ┌──────────┴──────────┐
              │                     │
         Menu actions          Settings...
              │                     │
              ▼                     ▼
     Global Shortcut          SwiftUI Settings Window
     (toggle recording)       (LLM config, prompts, shortcuts)
              │
              ▼
    ┌─── Recorder State Machine ───┐
    │                              │
    │  .idle                       │
    │  .recording                  │ ← ScreenCaptureKit + AVAudioEngine
    │  .transcribing               │ ← AVAudioConverter → chunk → Core ML
    │  .actionSelection            │ ← user picks ⌘1 or ⌘2
    │  .processing                 │ ← transcript + prompt → LLM
    │  .done(result)               │ ← result shown in overlay
    │  .error                      │
    │                              │
    └──────────────────────────────┘
              │
              ▼
    NSPanel floating overlay
    (state-driven UI, draggable)
```

### Key Components

1. **AppDelegate / App** — `NSStatusItem` setup, global shortcut registration
2. **RecorderStateMachine** — drives the full lifecycle, publishes state changes
3. **AudioCaptureService** — manages ScreenCaptureKit + AVAudioEngine, mixes streams
4. **TranscriptionService** — resamples, chunks, runs Core ML/ONNX inference
5. **LLMService** (protocol) — `OllamaProvider`, `ClaudeCLIProvider`, `GeminiCLIProvider`
6. **ConfigManager** — loads/saves settings, exposes to Settings UI
7. **OverlayWindow** — `NSPanel` subclass, SwiftUI content, always-on-top, draggable

### Build System
- Uses **`make`** as the build tool
- Required targets:
  - `make clean` — removes build artifacts
  - `make build` — compiles the project
  - `make install` — installs the app to `/Applications`

### Platform Requirements
- macOS 15 (Sequoia) or later
- Screen Recording permission (system audio)
- Microphone permission
