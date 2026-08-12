# Notch Shelf Redesign — Design Spec

**Date:** 2026-08-12
**Status:** Approved (design), pending implementation plan
**Author:** Leon Creed-Baker (design dialogue with Claude)
**Branch:** `claude/notch-feature-improvements-377226`

## 1. Overview

The notch grows from a single hover panel into Mustard's **command shelf**: a tabbed,
pinnable, searchable surface in the Supaste layout (tab pills with counts, corner
buttons, card grid), carrying Mustard's own surfaces (Today, Agent, Meetings) plus a
new **clipboard layer** (Clips history, Shelf staging, custom collections)
cherry-picked from the Helm/DockDoor/LaunchMe feature review.

### Decisions locked during brainstorming

- **Helm relationship: cherry-pick.** Window management, app launching, and Spaces
  stay in Helm (`~/Documents/Cavehole/Helm`). Mustard's notch takes the
  Supaste-shaped pieces: clipboard history, shelf, pins, tabs, search.
- **Mustard owns clipboard capture.** One `NSPasteboard` poller on the system.
  Retiring Helm's clipboard panel is a follow-up in the Helm repo, not this change.
- **Tabs: fixed five + custom.** Today · Agent · Meetings · Clips · Shelf, plus
  user-created collections via a `+` pill.
- **Interaction: hover + click-to-pin.** Hover peeks (with a collapse grace period);
  click, ⌘⇧N, or ⌃⌥V pins; Esc / click-away unpins.
- **Clip actions:** click copies; Return or double-click pastes into the frontmost
  app via the existing `TextInserter`/`PasteboardSnapshot` path; drag-out works.
  ⌃⌥V opens the panel pinned on Clips with search focused.
- **Clips vs Shelf:** Clips is automatic history (everything copied + dictations,
  200-item rolling prune). Shelf is deliberate keeps (drag-in or "pin to Shelf",
  never auto-pruned). Same card UI, opposite lifecycle.
- **Dictation history:** completed ⌃⌥D dictations land in Clips with a Dictation
  source badge. This deliberately reverses the earlier "never into Mustard's store"
  decision (`SystemDictationCoordinator.swift`) now that a private local home exists.
- **Meetings tab:** the recorder moves out of Today into its own tab, joined by
  upcoming meetings and recent recordings.

## 2. Surfaces

### Idle strip (unchanged visuals, two new behaviours)

The rotating ticker and status-dot logic (`NotchTicker`, dot precedence
recording-red → agent-purple → waiting-teal) stay exactly as shipped. New:

1. **Click pins** the expanded panel open.
2. **Drop target:** dragging files/text/images onto the strip (or anywhere on the
   expanded panel chrome) adds them to Shelf.

### Expanded panel

Top-to-bottom:

1. **Header row.** Search field (left); corner buttons (right): star = show pinned
   items, pin = keep-open toggle, ↗ = open Mustard (existing `NotchNavigation`).
2. **Suggestion banner slot.** The "looks like a meeting is starting" prompt
   (`MeetingStartPromptView`) renders here, above the tabs, visible from any tab.
   Same consent path; a suggestion can never start capture on its own.
3. **Tab pills with counts.** Today `n remaining` · Agent `n waiting` · Meetings ·
   Clips `n` · Shelf `n` · `+`. While recording, the Meetings pill carries the red dot.
4. **Tab content** (below).
5. **Quick-capture bar** ("Add to inbox…" + Add), persistent across tabs.

Panel size becomes content-driven per tab (min 420×460-ish, capped to screen);
no longer a single hardcoded frame.

### Tabs

- **Today.** Current content minus the recorder: agenda (`DayPlanner.agenda`),
  ritual prompt, progress capsule. Row interactions unchanged.
- **Agent.** The triage card expands into a read-only card list: pending
  recommendations and needs-review/needs-you tasks, each routing to the Agent
  console via `NotchNavigation`. **No inline Approve/Deny** — the 2026-07-02
  decision stands; the notch surfaces, the console acts.
- **Meetings.** Three stacked sections:
  - *Recorder* — `MeetingRecordingNotchView` moves here wholesale (idle → consent →
    recording → finalizing → ready/partial/failed). All decisions stay in
    `MeetingCaptureCoordinator`; consent remains non-negotiable.
  - *Upcoming* — next few `CalendarEvent`s with Join links.
  - *Recent recordings* — last ~10: title, date, duration, status; click opens the
    meeting note/digest (via `NotchNavigation` into Notes).
  - When recording state ≠ idle, expanding the panel auto-selects this tab.
- **Clips.** Card grid, newest first. Card = type-appropriate preview (text snippet,
  URL, color swatch, image thumbnail, file name) + source-app badge + relative
  timestamp. Filter chips by type (Text · Links · Images · Files · Colors ·
  Dictations). Click copies; Return/double-click pastes into the frontmost app;
  drag-out to any app; context menu: pin to Shelf, add to collection, delete.
- **Shelf.** Same card grid; items arrive by drag-in or "pin to Shelf"; removed only
  explicitly. Never auto-pruned.
- **Custom collections (`+`).** Named buckets (e.g. Prompts, Colors). Clips are
  filed by drag or context menu. Collection tabs render after Shelf, with counts.
  Deleting a collection returns nothing to history — items in a collection are
  exempt from pruning while filed.

### Search

The header search filters the clipboard layer (Clips, Shelf, collections) with
fuzzy matching. Tasks/notes are out of scope — ⌘K already owns them.

### Hotkeys

- ⌘⇧N — toggle panel (now opens *pinned*). Existing.
- ⌃⌥V — open pinned on Clips, search focused. Registered via the same Carbon
  hot-key mechanism as ⌃⌥Space/⌃⌥D/⌃⌥R; a chord conflict is surfaced, never silent.

## 3. Architecture

New code follows the house separation rule: decisions in `Logic/` (pure, TDD),
capture/IO in a service layer, views render-and-dispatch only.

### New: `Sources/MustardKit/Clipboard/`

| Unit | Responsibility |
|---|---|
| `ClipboardMonitor` | Polls `NSPasteboard.general.changeCount` (~1 s timer). Reads text/URL/image/file-URL representations. Skips transient/concealed types (`org.nspasteboard.ConcealedType`, `.TransientType`, `.AutoGeneratedType`) and excluded bundle IDs. Emits a `ClipCandidate` value; all accept/classify/dedupe decisions live in pure logic. |
| `ClipStore` | Applies `ClipStoreRules` to candidates against SwiftData; performs prune deletes. |

### New models (SwiftData, `Models/`)

- `ClipItem` — kind (text/link/color/image/file/dictation), string payload,
  image data (downsampled thumbnail + capped original ≤ ~5 MB), source bundle ID +
  app name, createdAt, `pinnedToShelf: Bool`, optional collection relationship.
  Shelf membership is the flag, not a separate model — "pin to Shelf" is a toggle,
  and pruning simply skips pinned/filed items.
- `ClipCollection` — name, sortOrder, items relationship.

### New pure logic (`Logic/`, one test file per unit)

| Unit | Decides |
|---|---|
| `NotchPinState` | hover/pin state machine: peek-on-hover, grace-period collapse (~300 ms), pin via click/hotkey, unpin via Esc/click-away. Injected clock. |
| `ClipClassifier` | candidate → kind (color hex/rgb detection, URL, file, image, text) |
| `ClipStoreRules` | accept/skip (excluded bundles, concealed, consecutive dupes), prune plan (oldest unpinned/unfiled beyond 200) |
| `NotchTabModel` | tab list incl. collections, counts, default-tab selection (recording → Meetings), which tab ⌃⌥V/⌘⇧N lands on |
| `NotchSearch` | fuzzy filter + ranking over clip summaries |

Excluded bundle IDs default to 1Password and Keychain Access as constants in
`ClipStoreRules` (user-editable config deferred).

### Views (`Views/`)

`NotchSurface.swift` decomposes: `NotchController` (panel lifecycle, geometry —
extended for pinning + variable size) stays; `NotchView` becomes a shell (header,
banner slot, tab pills, capture bar) hosting one view per tab:
`NotchTodayTab`, `NotchAgentTab`, `NotchMeetingsTab`, `NotchClipsTab`,
`NotchShelfTab`, `NotchCollectionTab`. The dark-palette exception carries over to
all of them: explicit dark hex, never `Theme`.

Paste-back reuses `TextInserter` + `PasteboardSnapshot` (dictation's verified-⌘V
machinery). Accessibility permission is already part of the dictation setup path.

### Dictation persistence

`SystemDictationCoordinator` gains an injected completion hook; on successful
insert (or fallback), the final transcript is offered to `ClipStore` as a
`.dictation` candidate. Failure to store never affects insertion.

### Fixes rolled in

- `NotchController` observes `NSApplication.didChangeScreenParametersNotification`
  and re-resolves its screen (today it only re-resolves on show/hover).
- `VoiceCapturePillView` placement switches from `NSScreen.main` to
  `NotchScreenPicker` so all top-of-screen surfaces agree on a display
  (`SystemDictationCoordinator`'s pill too).

## 4. Data & persistence

Everything in `mustard.store` (SwiftData), local-only, no network. Retention:
200 unpinned/unfiled clips; images capped as above. Deleting is real deletion.

**Privacy:** capture is on-device only; concealed/transient pasteboard types are
never stored; password-manager bundles are excluded; dictation transcripts are
stored only after this spec's deliberate reversal (documented here and in code
comments at the old "never into Mustard's store" site).

## 5. Key flows

- **Copy anywhere** → ClipboardMonitor picks it up ≤1 s → card at top of Clips.
- **Dictate (⌃⌥D)** → text inserted as today → transcript appears in Clips
  (Dictation badge).
- **Reuse a clip** → hover notch (or ⌃⌥V) → click card (copy) or Return (paste into
  frontmost app) or drag it out.
- **Keep something** → drag file onto notch → Shelf; or context-menu "pin to Shelf".
- **Meeting** → hover → Meetings tab (auto-selected if recording) → start/pause/stop
  with the same consent flow; recent recording → click → digest note.
- **Triage glance** → Agent tab shows what's waiting → click → Agent console.

## 6. Testing strategy

- **TDD pure units:** `NotchPinStateTests`, `ClipClassifierTests`,
  `ClipStoreRulesTests`, `NotchTabModelTests`, `NotchSearchTests`, plus updates to
  `NotchTickerTests`/`NotchScreenPickerTests` only if their contracts move.
  Time-dependent logic takes injected `now:`/clock, pinned UTC calendars.
- **Service layer:** `ClipboardMonitor` pasteboard reads behind a protocol so
  accept/dedupe paths are testable with fake pasteboards; `ClipStore` tested
  against an in-memory container.
- **Views:** `swift build` + Leon's eye. The session shell has no TCC, so hover,
  pinning, drag-drop, paste-back, and the ⌃⌥V hotkey get a manual checklist item
  each in the PR body rather than claimed sight-unseen.

## 7. Explicitly out of scope (YAGNI)

- Window previews, app launching, Spaces — Helm's job.
- Retiring Helm's clipboard panel — Helm repo follow-up.
- OCR, iCloud sync of clips, inline snippet expansion (";welcome"), ⌃⌥0–9
  quick-paste, ML sensitive-content detection, Apple Intelligence clip rewriting.
- Editable exclusion list UI; per-collection settings.
- iOS: models ship in MustardKit but no notch/clipboard surface on iOS.

## 8. Risks

- **Pasteboard polling** is the only supported capture mechanism; 1 s cadence is
  the Helm/Supaste norm and cheap, but the monitor must never block the main actor.
- **Image payload growth** — mitigated by the ≤5 MB cap + thumbnails + pruning.
- **Paste-back focus edge cases** — reusing the dictation inserter keeps this to
  one battle-tested code path; the notch panel is non-activating so the frontmost
  app keeps focus.
- **Hotkey conflicts** — ⌃⌥V may collide with user software; the Carbon layer
  surfaces conflicts like ⌃⌥Space does.
