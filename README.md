# Heed

A macOS menubar app that records meetings, transcribes locally via [Parakeet TDT 0.6B V3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), and processes transcripts through LLMs — all on-device, no cloud required.

## Features

- **Menubar-only** — no dock icon, stays out of the way
- **Mic + system audio** — captures your voice and meeting app audio (Zoom, Teams, Google Meet, etc.) simultaneously via ScreenCaptureKit
- **Local transcription** — Parakeet TDT 0.6B V3 Core ML model runs entirely on-device (~600 MB one-time download)
- **Global shortcut** — `⇧⌘R` starts and stops recording from any app
- **Post-transcription actions** — after transcription, press `⌘1` to summarize or `⌘2` for meeting feedback
- **LLM providers** — Claude CLI, Gemini CLI, or Ollama; configurable in Settings
- **Customizable prompts** — edit the summary and meeting feedback prompts in Settings
- **Configurable shortcuts** — all overlay key bindings (Discard, Copy, Summarize, Feedback) can be rebound in Settings

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon or Intel Mac with Core ML support
- Microphone permission
- Screen Recording permission (for system audio capture)
- At least one LLM installed: [Claude CLI](https://claude.ai/code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), or [Ollama](https://ollama.ai)

## Build

Requires Xcode command-line tools and [Swift Package Manager](https://swift.org/package-manager/).

```bash
# Build release app bundle and codesign
make build

# Install to /Applications/
make install

# Clean build artifacts
make clean
```

On first launch, Heed will prompt you to download the Parakeet Core ML model (~600 MB) from Hugging Face. This is a one-time download stored at `~/Library/Application Support/FluidAudio/Models/`.

## Usage

1. Launch Heed — an ear icon (`⌫`) appears in the menubar
2. Grant Microphone and Screen Recording permissions when prompted
3. Press `⇧⌘R` (or use the menubar) to start recording
4. Press `⇧⌘R` again to stop — transcription runs automatically
5. When the transcript appears, press `⌘1` to summarize or `⌘2` for meeting feedback
6. Press `↵` to copy the result to the clipboard, or `⎋` to discard

## Overlay States

Heed uses a floating overlay panel anchored near the top of your screen. It progresses through these states during a session:

### Recording
A compact panel (160 px) with an animated waveform visualising the live mic/system audio mix. The `⇧⌘R` hint is shown at the bottom.

Press `⇧⌘R` to stop recording and begin transcription.

### Transcribing
The waveform is replaced by a spinner and "Transcribing…" label while Parakeet processes the audio on-device. `⇧⌘R` is ignored during this phase.

### Transcript
The panel expands (380 px) and shows the full transcript text in a scrollable view. Four key hints appear in the footer:

| Key | Action |
|-----|--------|
| `⎋` | Discard transcript and close |
| `↵` | Copy transcript to clipboard and close |
| `⌘1` | Send to LLM for **Summarize** |
| `⌘2` | Send to LLM for **Meeting Feedback** |

### Summarizing / Analyzing
A spinner with a status label ("Summarizing…" or "Analyzing…") is shown while the LLM processes the transcript. Key input is suspended during this phase.

### Result
The panel shows the LLM's response in a scrollable view. Two key hints appear:

| Key | Action |
|-----|--------|
| `⎋` | Discard result and close |
| `↵` | Copy result to clipboard and close |

All key bindings shown in the overlay footer reflect your current Settings configuration.

## Settings

Open via **menubar icon → Settings…** (`⌘,`).

### Key Bindings
Rebind any of the four overlay shortcuts — click a row to enter recording mode, then press your desired key combination. Reset to defaults at any time.

| Action | Default |
|--------|---------|
| Discard | `⎋` |
| Copy Transcript / Result | `↵` |
| Summarize | `⌘1` |
| Meeting Feedback | `⌘2` |

### LLM
Choose a provider and configure it:

| Provider | How it works | Config |
|----------|-------------|--------|
| **Claude CLI** | Shells out to `claude` binary via `zsh -l`; transcript piped via stdin | Optional path to binary (leave blank to use `$PATH`) |
| **Gemini CLI** | Shells out to `gemini` binary via `zsh -l`; transcript piped via stdin | Optional path to binary (leave blank to use `$PATH`) |
| **Ollama** | HTTP POST to `/api/generate` (stream: false) | Endpoint URL (default `http://localhost:11434`) + model name (default `llama3`) |

CLI providers run via a `zsh` login shell so they inherit your full environment (auth tokens, Node.js path, etc.).

### Prompts
Edit the prompt text sent to the LLM for each action. Changes take effect on the next invocation.

| Action | Default behaviour |
|--------|------------------|
| **Summarize** | Concise bullet-point summary of topics, decisions, and action items |
| **Meeting Feedback** | Structured analysis: decisions, action items, open questions, sentiment, follow-ups |

## Architecture

| Component | Description |
|-----------|-------------|
| `HeedApp.swift` | `NSApplicationDelegate` entry point; recording lifecycle, audio mixing, LLM dispatch |
| `AudioCaptureService.swift` | Mic capture via AVAudioEngine, resamples to 16 kHz |
| `SystemAudioCapture.swift` | System audio capture via ScreenCaptureKit |
| `ModelManager.swift` | Parakeet model lifecycle via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| `OverlayWindow.swift` | Floating `NSPanel`; drives all overlay states and key event handling |
| `GlobalShortcutManager.swift` | Carbon `RegisterEventHotKey` for `⇧⌘R` |
| `ConfigManager.swift` | `UserDefaults`-backed settings singleton; key bindings, LLM config, prompts |
| `SettingsWindow.swift` | `NSWindowController` + SwiftUI settings UI (Key Bindings / LLM / Prompts tabs) |

**Audio pipeline:** mic (AVAudioEngine, native rate) + system audio (SCStream, 48 kHz) → downmix to mono → resample to 16 kHz → mix (60% mic / 40% system) → Parakeet transcription.

**Swift 5 mode** is intentional — AVAudioEngine's `installTap` callback runs on a realtime audio thread, and Swift 6 strict concurrency traps on actor isolation crossings from that context.

## Dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Swift wrapper for Parakeet TDT Core ML inference

## License

MIT — see [LICENSE](LICENSE).
