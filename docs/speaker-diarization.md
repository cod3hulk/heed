# Speaker diarization roadmap

## Decision

Implement speaker intelligence in two stages:

1. **MVP: speaker diarization** — local, on-device "who spoke when" labels such as `Speaker 0` / `Speaker 1`.
2. **Later: speaker recognition** — optional local speaker profiles / embeddings that map diarized speakers to known people after explicit enrollment.

This keeps the first release useful without requiring users to register voices or store identity data.

## Current implementation

- Audio is captured and mixed in `HeedApp.stopRecordingAndTranscribe()` as 16 kHz mono samples.
- The same 16 kHz buffer is sent to:
  - Parakeet ASR via `ModelManager.transcribeDetailed(_:)` for transcript text and token timings.
  - FluidAudio `OfflineDiarizerManager` via `SpeakerDiarizationService` for speaker time segments.
- `SpeakerDiarizationFormatter` joins ASR token timings to diarization segments and renders labels in the overlay/export text:

```text
[00:12–00:18] Speaker 0: ...

[00:18–00:24] Speaker 1: ...
```

If ASR token timings are unavailable, Heed falls back to a speaker timeline plus the raw transcript. If diarization fails or its models are unavailable, Heed falls back to the plain transcript.

## Edge cases and fallbacks

- Very short gaps for the same speaker are merged to avoid noisy rapid switches.
- Low-confidence segments are rendered as `Unknown speaker` instead of over-confident labels.
- Silence and overlap are delegated to the FluidAudio offline diarization pipeline; overlapping speech is represented only as the emitted segments in the MVP.
- All diarization runs locally. Model download/cache behavior follows FluidAudio's default local Core ML cache.

## Stage 2 preparation

Future speaker recognition should add:

- A local speaker-profile store containing display name, embedding vector(s), creation date, and user opt-in metadata.
- Enrollment UI to record or select a short reference sample and name/delete the profile.
- Matching from diarized speaker embeddings to enrolled profiles with a conservative confidence threshold.
- A correction UI so users can rename `Speaker N` labels and optionally save that correction as an enrolled profile.
- Privacy controls: local-only storage, opt-in enrollment, clear delete/export controls.

## Verification

- Unit tests cover transcript/diarization formatting, fallback labels, and manual label rename support.
- Manual validation should use local macOS sample recordings with one, two, and multiple speakers; Linux CI is not a meaningful target for Core ML/AppKit behavior.
- Run `make test` for deterministic core regression tests and `make build` on macOS before shipping.
