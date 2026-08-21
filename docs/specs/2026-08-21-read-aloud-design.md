# Read Aloud — Design

- **Status:** Spec — awaiting Leon's approval. No code written.
- **Date:** 2026-08-21
- **Origin:** the Talkify review (`tornikegomareli/Talkify` ships a `ReadAloud/` module
  on ⌥⎋); Leon asked whether a Speechify-style read-back is feasible.
- **Depends on:** `Dictation/AccessibilityFocusReader` (selection reading),
  `Capture/PushToTalkHotKey` (global chord), the non-activating pill pattern.
- **Branch:** not started.

## Problem

Mustard can hear you (⌃⌥Space capture, ⌃⌥D dictation) and rewrite you (⌃⌥R), but it
cannot read back to you. Proofreading a draft by ear catches clumsy sentences that
re-reading them silently does not, and there are stretches of the day — walking, washing
up, away from the screen — where a meeting digest or an agent's output could be consumed
but currently cannot.

## Goal

Press a chord anywhere; Mustard speaks the selected text. Inside Mustard's own editors,
follow along with the spoken word highlighted.

## Non-goals (state these plainly before building)

- **Speechify-grade voices.** Apple does not expose Siri voices to third-party apps:
  `AVSpeechSynthesisVoice.speechVoices()` omits them even once the user has downloaded
  them in System Settings, and there is no API to enumerate downloadable voices at all.
  We get the Enhanced/Premium non-Siri voices (Ava, Evan, …), which the user must install
  manually. Matching Speechify means a network TTS API — per-character billing and a
  break with the on-device, no-network principle the whole voice suite rests on. Out of
  scope; revisit only as an explicit, separately-approved decision.
- **Word highlighting outside Mustard.** We cannot repaint Safari or Slack. Highlighting
  is Mustard-surfaces-only, by construction, not by omission.
- **Queues, playlists, reading history, offline export.** Not this iteration.

## Approach

`AVSpeechSynthesizer`, on-device, free, no entitlement. Two thirds of the work already
exists: `AccessibilityFocusReader` reads `kAXSelectedTextAttribute` into
`FocusedTextTarget.selectedText`, and `PushToTalkHotKey` already owns a Carbon chord
registry. The new surface is a player and its state machine.

The synthesizer's delegate reports `willSpeakRangeOfSpeechString`, giving a character
range per spoken word. That single callback is what makes the karaoke highlight possible
where we own the text view.

## Components

### 1. `Logic/ReadAloudPlan` (pure, TDD)

Turning arbitrary selected text into something worth listening to is where the decisions
live, so it goes here:

- **Sentence segmentation** for seek-by-sentence and resume-at-boundary, so a pause and
  resume does not restart a paragraph.
- **Speakable normalization.** Markdown selected out of the Notes editor should not be
  read as punctuation soup: strip `#`/`*`/backticks, read `[label](url)` as its label,
  skip fenced code blocks (announce "code block skipped" rather than spelling out
  symbols), and collapse wikilink syntax to the target's display text.
- **Length guard.** Refuse (with a reason) above a bound rather than starting a
  forty-minute read the user cannot see the end of.
- **Empty/whitespace selection** → a stated refusal, never silence.

### 2. `ReadAloud/SpeechOutput` (seam)

A protocol over `AVSpeechSynthesizer` — `speak`, `pause`, `resume`, `stop`, rate/voice
selection, plus the word-range callback. Tests inject a stub; the coordinator never
touches AVFoundation directly. Mirrors how `SpeechAnalyzerDriving` isolates the
recognizer.

### 3. `ReadAloud/ReadAloudCoordinator` (`@MainActor @Observable`)

Owns the chord, the current utterance, and the player state
(`idle · speaking · paused · finished · refused(String)`). Reads the selection at press
time through `AccessibilityFocusReader` — a snapshot, exactly as dictation takes one — so
what is spoken is what was selected when you asked, even if focus later moves.

### 4. `Views/ReadAloudPillView`

The non-activating floating panel the dictation and capture pills already establish:
play/pause, ⏭ sentence, speed, and the current sentence as text. Never steals focus.
Follows `Theme` (it is not the notch, so it is light).

### 5. Hotkey

`PushToTalkHotKey` id **5** on the existing `"MSTD"` Carbon signature (1 capture,
2 dictation, 3 rewrite, 4 clips). Toggle semantics, not hold: press to start, press again
to stop. Rebindable in Settings → Hotkeys with the rest. Suggested default ⌃⌥A — ⌥⎋ is
Talkify's and would clash for anyone running both.

### 6. Highlighting (Mustard surfaces only)

`MarkdownTextView` is TextKit 1, so a temporary background attribute over the spoken
range is natural. Applies to the Notes editor, meeting transcripts, and agent output
cards. Outside Mustard the pill shows the current sentence as text instead — the same
information, without the paint.

## Interlocks

- **Meeting capture.** Read-aloud output is system audio and would be recorded by
  `ScreenCaptureMeetingAudio` into the meeting transcript. Refuse to start (with a stated
  reason) while a meeting recording is live, or duck it. Talkify carries an
  `AudioDucker` for the same reason. **This must be decided before implementation, not
  discovered afterwards.**
- **Voice capture / dictation.** Speaking while the mic is hot feeds the recogniser our
  own synthesized voice. Read-aloud must stop when a capture or dictation chord fires.
- **No store.** Like dictation, this holds no `ModelContext`. Nothing is persisted.

## Test plan

- `Logic/ReadAloudPlan`: segmentation, markdown normalization, code-block skipping,
  length guard, empty-selection refusal — pure, fixed fixtures, one file per unit.
- `ReadAloudCoordinator` against a stubbed `SpeechOutput`: state transitions, the
  selection snapshot at press, stop-on-capture, refuse-during-meeting.
- Views by build + Leon's eye and ear. Voice quality in particular is a judgement call
  only Leon can make, and it is the thing most likely to sink the feature — get a build
  in front of him before any polish.

## Estimate

- Selection → speech, pill, hotkey, interlocks: **~1 day.**
- Highlighting in `MarkdownTextView` + Notes/transcript integration: **~1–2 days more.**

Ship the first half, listen to it, then decide whether the second half is worth it.

## Open questions for Leon

1. Voice quality is the risk. Are you willing to install a Premium voice in System
   Settings, or does this need to sound better than the system can manage — in which case
   it is a different (networked, paid) feature and should be judged as one?
2. During a meeting recording: refuse, or duck and record?
3. Default chord — ⌃⌥A, or something else?
