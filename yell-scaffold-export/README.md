# Yell

**Don't whisper.**

Yell is a satirical Mac command centre: system-wide dictation, listen-aloud, Blitzit-style focus tasks, Granola-style meetings, and Mustard-grade clipboard history — with escalating ridiculousness and hidden easter eggs built for free marketing.

> Product hub (Notion): [YELL](https://app.notion.com/p/3c10870d4c44801fa5f6e8a20919410d)

## What it does

| Pillar | Job |
|--------|-----|
| **Hold to Yell** | Push-to-talk dictation into any focused text field |
| **Yell this** | Read selected text aloud (Apple voices free; premium cloud on Pro) |
| **Blitz tower** | Floating task list + focus timer ([Blitzit](https://www.blitzit.app/) DNA) |
| **Yell the meeting** | Record, transcribe, summarize; basic summary free, richer digest + action items on Pro |
| **Clips shelf** | Clipboard history — copy, paste, pin, search (Mustard notch DNA) |

## Engineering approach

This is a **separate commercial app**, not a Mustard fork. We **lift proven modules** from [Mustard](https://github.com/ch-leon/Mustard) into `YellKit`:

- Dictation stack (AX insert, pasteboard restore, hotkeys, speech session)
- Clipboard / Clips monitor + store
- Meeting capture + transcription + digest
- Voice capture patterns (adapted for tasks, not agent delegation)

The product shell, brand, monetization, and easter eggs are **built fresh**.

## Repo layout

```
Yell/
  Package.swift          # YellKit library + Yell executable
  build-app.sh           # Assembles Yell.app (macOS)
  Sources/
    Yell/                # @main app — menu bar, windows, wiring
    YellKit/             # Models, logic, voice, dictation, clips, meetings
  Tests/
    YellTests/           # Pure logic tests (TDD for YellKit)
  docs/
    extraction-map.md    # Mustard → Yell module lift checklist
```

## Requirements

- macOS 26+ (live SpeechAnalyzer path targets macOS 27+)
- Swift tools 6.2, language mode Swift 5
- Xcode / plain toolchain (do **not** pin `DEVELOPER_DIR` to beta unless needed)

## Build (once modules land)

```bash
swift test
swift build
./build-app.sh   # → build/Yell.app
```

## Monetization (product)

- **Free:** on-device STT/TTS, Blitz tower, Clips shelf, meetings with basic summary
- **Pro:** premium voices, richer meeting digests, action items → Blitz, absurd presets

## Status

**Phase 0 complete** — product defined in Notion. **Phase 1 next** — lift dictation core into `YellKit`.

## License

Proprietary. All rights reserved.
