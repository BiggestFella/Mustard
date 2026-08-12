# ⌃⌥R on-device rewrite — cross-app acceptance matrix

**Status:** unfilled. Everything below is **unverified on hardware**. The suite
is green and the app builds, but the voice suite found eleven runtime bugs that
1,443 passing tests could not reach, and every one lived in this exact layer
(Accessibility, Carbon, pasteboard, panel focus). Nothing here may be called
working until a row is filled in from a real run.

Only Leon can run this: the agent's shell has no Screen Recording / TCC grant
and cannot drive or observe the native app.

## Before starting

1. `./build-app.sh && open build/Mustard.app` — test the fresh binary, never a
   stale one.
2. Grant Accessibility if macOS asks (System Settings → Privacy & Security →
   Accessibility). Rewrite reuses dictation's grant; it adds no new permission.
3. Stream the boundary trace in a terminal and keep it visible:

```bash
log stream --predicate 'subsystem == "com.cavehole.mustard" AND category == "rewrite"'
```

Each invocation should emit `snapshot` → `gate` → `read` → `generated`, then
`reassert` → `write` on accept. Selection text is never logged, only lengths.

## How to run one row

Select a sentence, tap **⌃⌥R**, wait for the card, then:
`Return` replaces · `Esc` discards · `1`–`4` switch intent · `⌃⌥R` another take.

Record what the log says, not what it looked like.

| Target | Focused role / subrole | Read rung that won | Write path | Selection survived the card? | Notes |
|---|---|---|---|---|---|
| Mustard notes editor | | | | | proves prompt + card independent of AX |
| Notes.app or Mail | | | | | native Cocoa: expect rung 1/2 + direct write |
| Gmail in Chrome | | | | | Chromium web area: expect rung 3 (⌘C) + paste |
| Slack | | | | | Electron — reports AX writes as successful while discarding them |
| Linear in a browser | | | | | second web-area data point |
| Xcode | | | | | non-trivial native text view |
| **Any password field** | | **must refuse** | **none** | n/a | **Non-negotiable: no read, no ⌘C, no write** |

## What a failure looks like, and what it is not

- **"Couldn't read the selection in X"** — all three rungs failed. The log line
  records the role/subrole; add it here and consider widening
  `RewriteRoles.textual` (rewrite's own set — never dictation's).
- **Card appears but Return does nothing** — the panel is not key. That is the
  `canBecomeKey` override, not the write path.
- **Mustard jumps forward when the card opens** — a regression: `NSApp.activate`
  must never be called on this path (voice bug #7).
- **The clipboard changed after a rewrite** — the rung-3 restore failed. The
  restore is deliberately skipped when something else wrote to the pasteboard
  during the copy, so check whether another app was involved.
- **A rewrite that is merely bad** is a prompt problem, not a plumbing problem.
  Note it separately; phase 2's voice profile is where that gets fixed.
