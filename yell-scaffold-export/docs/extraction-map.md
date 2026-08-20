# Mustard → Yell extraction map

Checklist for lifting proven modules into `YellKit`. Copy and adapt — do not fork Mustard.

## Phase 1 — Voice core

| Mustard path | Yell destination | Notes |
|--------------|------------------|-------|
| `Dictation/*` | `YellKit/Dictation/` | Coordinator, AX insert, pasteboard |
| `Logic/FocusedTextTarget.swift` | `YellKit/Logic/` | Pure |
| `Logic/DictationWhitespace.swift` | `YellKit/Logic/` | Pure + tests |
| `Voice/AppleSpeechSession.swift` | `YellKit/Voice/` | Extract mic feed from capture file |
| `Capture/PushToTalkHotKey.swift` | `YellKit/HotKey/` | New Carbon signature `YELL` |
| `Views/SystemDictationPillView.swift` | `YellKit/Views/` | Reskin for Yell brand |
| Matching tests in `MustardTests/` | `YellTests/` | Port verbatim where possible |

## Phase 2 — Listen + Clips

| Mustard path | Yell destination | Notes |
|--------------|------------------|-------|
| `Clipboard/*` | `YellKit/Clipboard/` | Monitor, store, paster |
| `Logic/Clip*.swift` | `YellKit/Logic/` | Classifier, rules, search |
| `Views/ClipCardView.swift` | `YellKit/Views/` | Reskin |
| Selection reader (Rewrite) | `YellKit/Listen/` | Input for Yell this |
| `Logic/NotchPinState.swift` | `YellKit/Shelf/` | Pin/hover shell |

## Phase 3 — Blitz tower

| Mustard path | Yell destination | Notes |
|--------------|------------------|-------|
| Voice task capture pattern | `YellKit/Blitz/` | Yell-a-task, not Inbox |
| `Logic/VoiceCapture.swift` | `YellKit/Logic/` | Shared hold/segment rules |

## Phase 4 — Meetings

| Mustard path | Yell destination | Notes |
|--------------|------------------|-------|
| `Meeting/*` | `YellKit/Meeting/` | Record, transcript, digest |
| Meeting Logic/* | `YellKit/Logic/` | Pure rules |

## Leave in Mustard

- `Agent/*`, Claude runner, vault sweep, board, recommendations
- SwiftData task/board models tied to agent lanes
- Mustard Theme tokens (Yell gets its own palette)

## Rename / rewire

- Bundle ID: `com.cavehole.yell` (not `com.cavehole.mustard`)
- Carbon hotkey signature: `YELL` (not `MSTD`)
- UserDefaults keys: `yell.*` prefix
- No `MustardTask` — Yell task model is Blitz-scoped
