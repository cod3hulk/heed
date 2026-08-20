# AGENTS.md

Guidance for AI coding agents working in this repository.

The canonical project instructions live in [CLAUDE.md](./CLAUDE.md). Read that file first — it contains the full build commands, architecture overview, testing workflow, and macOS-specific gotchas.

## Quick Reference

```bash
make build     # swift build -c release → app bundle → codesign
make test      # run unit tests (no Xcode required)
make clean     # swift package clean + rm build/
make install   # build + rsync to /Applications/
```

## Critical Rules

- **Swift 6 concurrency:** Package.swift uses `.swiftLanguageMode(.v5)`. The AVAudioEngine `installTap` closure must ONLY use raw C pointers and value types — no `[weak self]` capturing `@MainActor` classes, no passing `AVAudioPCMBuffer` to functions.
- **Run `make test` before committing any audio pipeline changes.** Tests live in `Tests/HeedTests/main.swift` as a standalone executable — keep them deterministic and fast (no hardware or network).
- **Permissions must be requested upfront** in `requestPermissionsUpfront()` at launch — macOS kills the process when granting mic/screen-recording permission.

See [CLAUDE.md](./CLAUDE.md) for the complete architecture breakdown (entry point, audio pipeline, HeedCore, overlay, LLM dispatch, settings, config persistence).
