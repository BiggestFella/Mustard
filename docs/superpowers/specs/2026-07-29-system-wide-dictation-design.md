# System-Wide Dictation — Design

**Date:** 2026-07-29
**Status:** Approved (design), pending written spec review → implementation plan
**Parent:** [Mustard Voice Suite](2026-07-29-mustard-voice-suite-design.md)

## Goal

Let Leon dictate into the current text field in another Mac app without invoking
Apple's keyboard dictation or creating a Mustard task.

Success is: focus a normal text field, hold `⌃⌥D`, speak, release, and receive the
final on-device transcript at the original cursor with the surrounding app and
clipboard otherwise unchanged.

## User experience

1. Leon focuses a text field in any compatible app.
2. Holding `⌃⌥D` snapshots the active app, focused accessibility element,
   selection/range where available, and pasteboard state.
3. A nonactivating floating pill indicates listening and displays provisional
   text. It must not steal focus from the target app.
4. Releasing finalizes the transcript and inserts it at the snapshotted target.
5. A successful insertion briefly confirms completion; no Mustard task is
   created.

The shortcut is push-to-talk, not a start/stop toggle. Holds below the shared
minimum duration and empty transcripts cancel without modifying the target.

## Text insertion strategy

Insertion is best-effort because macOS apps expose different accessibility
implementations.

1. **Direct Accessibility insertion:** when the focused element exposes a
   writable selected-text value/range, replace the selection directly.
2. **Paste fallback:** when direct insertion is unsupported but the original
   app/element is still focused, place the transcript on the pasteboard, send a
   paste event to that application, verify the pasteboard change boundary, and
   restore the previous pasteboard contents.
3. **Safe recovery:** when the focus changed, the element is protected, or
   insertion cannot be confirmed, show the final transcript with **Copy** and
   **Try current field** actions. Never discard it.

The target identity is revalidated on release. Mustard must not insert into a
different field simply because focus moved during dictation.

Secure/password fields are always rejected. The implementation must also treat
remote-desktop canvases, custom editors, and web fields that hide accessibility
state as potentially unsupported rather than claiming universal compatibility.

## Speech and text behavior

Use the shared `AppleSpeechSession` with the current dictation locale, installed
assets, provisional/final reporting, and contextual vocabulary. The transcript
inserted is the speech engine's finalized text after deterministic whitespace
normalization.

V1 does not run the text through a generative model. This keeps insertion fast
and prevents a model from paraphrasing dictated content. Apple transcription
punctuation is retained.

Insertion whitespace is deterministic:

- Replacing a nonempty selection inserts exactly the normalized transcript.
- At an empty cursor, add a leading/trailing space only when adjacent characters
  require separation.
- Do not add whitespace next to newline boundaries or punctuation where it
  would be incorrect.

## Components

- `SystemDictationCoordinator`: hotkey and state-machine orchestration.
- `FocusedTextTarget`: plain snapshot value describing app, element, selection,
  protection state, and supported insertion modes.
- `FocusedTextReading`: injected Accessibility adapter.
- `TextInserting`: injected direct/paste implementation.
- `DictationWhitespace`: pure contextual insertion rules.
- `SystemDictationPillView`: rendering and recovery actions only.

The coordinator does not depend on SwiftData and creates no persistent task.
Failed final transcripts may remain in an in-memory recovery history for the
current app session; persistent dictation history is out of scope.

## Permissions

System dictation requires:

- Microphone
- Speech Recognition
- Accessibility

The Voice Setup screen explains why Accessibility is required and provides a
live test field. If Accessibility is denied, voice-task capture remains
available and dictation shows the final text with Copy rather than attempting
synthetic input.

## Error handling

- Hotkey registration collision is visible and configurable.
- Losing the target app or element during capture moves to safe recovery.
- Speech/asset errors do not touch the target field.
- Pasteboard restoration preserves all available pasteboard item types, not
  merely plain text.
- If another app changes the pasteboard during fallback insertion, Mustard does
  not overwrite that newer content when restoring.
- App termination during a short dictation makes no persistent mutation beyond
  text already inserted by the target app.

## Tests

TDD-first tests cover:

- Capture state transitions and short-hold cancellation.
- Original target identity is retained and revalidated.
- Focus change prevents insertion into the wrong field.
- Secure fields are rejected.
- Direct insertion success and unsupported-element fallback.
- Clipboard snapshot/restoration with multiple pasteboard types.
- Concurrent pasteboard change prevents stale restoration.
- Whitespace around letters, punctuation, selections, and newlines.
- No task or SwiftData mutation occurs.
- Failed insertion exposes recoverable final text.

Manual compatibility matrix:

- Native SwiftUI/AppKit field
- Safari text area
- Chrome text area
- Slack composer
- Gmail composer
- Notes
- Terminal
- At least one unsupported/secure field

## Acceptance criteria

1. `⌃⌥D` captures globally without activating Mustard.
2. Release inserts final text at the original compatible cursor.
3. Headphones do not affect microphone dictation beyond the selected input
   device.
4. Protected fields never receive text.
5. The clipboard is restored unless a newer external change would be lost.
6. Failure always leaves the transcript recoverable.
7. All speech processing stays on-device and no generative rewrite occurs.
8. `swift test` and `swift build` succeed; Leon confirms the compatibility
   matrix.

## Out of scope

- Voice commands such as "delete that" or "new paragraph".
- Toggle/continuous dictation mode.
- Persistent dictation history.
- Rewriting, summarising, or translating dictated text.
- Guaranteeing insertion into every custom or remote application.

## Proposed implementation slices

1. Accessibility permission/readiness and target snapshot model.
2. Pure target validation and whitespace rules.
3. Direct Accessibility insertion.
4. Pasteboard fallback and lossless restoration.
5. Global hotkey, nonactivating pill, and recovery UI.
6. Cross-app compatibility hardening.
