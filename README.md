# Heed

A macOS menubar app that records meetings, transcribes locally via [Parakeet TDT 0.6B V3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), and processes transcripts through LLMs — all on-device, no cloud required.

## Features

- **Menubar-only** — no dock icon, stays out of the way
- **Mic + system audio** — captures your voice and meeting app audio (Zoom, Teams, Google Meet, etc.) simultaneously via ScreenCaptureKit
- **Local transcription** — Parakeet TDT 0.6B V3 Core ML model runs entirely on-device (~600 MB one-time download)
- **Global shortcut** — `⇧⌘R` starts and stops recording from any app
- **Animated overlay** — floating waveform panel shows recording status

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon or Intel Mac with Core ML support
- Microphone permission
- Screen Recording permission (for system audio capture)

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

1. Launch Heed — an ear icon appears in the menubar
2. Grant Microphone and Screen Recording permissions when prompted
3. Press `⇧⌘R` (or use the menubar menu) to start recording
4. A floating waveform overlay confirms recording is active
5. Press `⇧⌘R` again to stop — transcription runs automatically

## Architecture

| Component | Description |
|---|---|
| `HeedApp.swift` | `NSApplicationDelegate` entry point, recording toggle, audio mixing |
| `AudioCaptureService.swift` | Mic capture via AVAudioEngine, resamples to 16 kHz |
| `SystemAudioCapture.swift` | System audio capture via ScreenCaptureKit |
| `ModelManager.swift` | Parakeet model lifecycle via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| `OverlayWindow.swift` | Floating `NSPanel` with animated waveform and recording status |
| `GlobalShortcutManager.swift` | Carbon `RegisterEventHotKey` for `⇧⌘R` |

**Audio pipeline:** mic (AVAudioEngine, native rate) + system audio (SCStream, 48 kHz) → downmix to mono → resample to 16 kHz → mix (60% mic / 40% system) → Parakeet transcription.

**Swift 5 mode** is intentional — AVAudioEngine's `installTap` callback runs on a realtime audio thread, and Swift 6 strict concurrency traps on actor isolation crossings from that context.

## Dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Swift wrapper for Parakeet TDT Core ML inference

## License

MIT — see [LICENSE](LICENSE).
