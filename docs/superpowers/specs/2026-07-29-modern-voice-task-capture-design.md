# Modern Voice-Task Capture — Design

**Date:** 2026-07-29
**Status:** Approved (design), pending written spec review → implementation plan
**Parent:** [Mustard Voice Suite](2026-07-29-mustard-voice-suite-design.md)

## Goal

Replace Mustard's legacy speech recognizer with Apple's current on-device speech
stack and make every voice-created task immediately editable without forcing a
full navigation into Mustard.

Success is: hold `⌃⌥Space`, speak, release, see a task appear in a
notch-adjacent editor, add or correct details such as URLs, and save without
losing the verbatim transcript.

## Current state

- `PushToTalkHotKey` globally registers `⌃⌥Space` with Carbon and supplies both
  pressed and released events.
- `SpeechTranscriber.swift` uses legacy `SFSpeechRecognizer`,
  `SFSpeechAudioBufferRecognitionRequest`, and `AVAudioEngine`.
- `VoiceCaptureController` turns a valid final transcript into an Inbox
  `MustardTask` with `source = "voice"` and `captureState = .raw`.
- `VoiceCapturePillView` renders live capture state.
- The background cleanup path currently delegates raw captures through the
  agent service.
- Existing task-detail drawer plumbing can open a task selected from the notch.

The global hotkey and pure minimum-hold/normalization logic remain useful. The
legacy speech implementation and cloud/CLI cleanup path do not remain in the
voice-suite v1.

## User experience

### Capture

1. Leon holds `⌃⌥Space`.
2. A nonactivating pill shows listening state and provisional transcription.
3. Release asks the analyzer to finalize through the last supplied audio time.
4. A too-short or empty capture cancels using the existing pure
   `VoiceCapture` rules.
5. A valid transcript creates the raw Inbox task immediately.

### Quick-edit card

After a successful release, a floating card opens directly below or adjacent to
the notch on the chosen display. It becomes key for editing without opening the
main Mustard window.

Fields:

- Title
- Notes/description
- URLs, supporting multiple validated links
- Area
- Schedule/date

Actions:

- `Return` saves and closes when focus is not in a multiline field.
- `⌘Return` saves and closes from anywhere in the card.
- `Escape` closes but keeps the task and all edits already made.
- **Open fully** brings Mustard forward and opens the existing task-detail
  drawer.
- Clicking outside closes while keeping the task.

The card initially shows the raw text in the title/notes presentation. An
on-device cleanup result can fill or propose a concise title, notes, area, and
schedule. Each field carries a local revision token: if Leon edits it after the
request begins, that field is not overwritten when the result arrives. Generated
URLs are never trusted solely from model output; URL values must parse and may
also be extracted deterministically from the raw transcript.

Only one quick-edit card is visible. A new capture commits the previous card's
current values, then presents the new task.

## Speech implementation

Use the shared `AppleSpeechSession`:

- Resolve a supported locale equivalent to the current dictation locale.
- Verify/install transcription assets with `AssetInventory`.
- Ask for provisional and final results, confidence, and audio-time metadata
  supported on the running macOS 27 build.
- Bias recognition through `AnalysisContext` using current areas, project names,
  contacts, and recent task vocabulary.
- Prewarm on app launch after permissions/assets are ready, then apply measured
  model-retention settings to reduce first-word latency without keeping heavy
  resources indefinitely.
- Keep the existing microphone engine only if required by the selected Apple
  input provider; otherwise prefer Apple's current capture input sequence
  provider.

Delete the legacy `SFSpeechRecognizer` implementation only after the modern path
passes the release smoke tests.

## On-device task cleanup

Define a guided output such as:

```swift
struct VoiceTaskDraft {
    var title: String
    var notes: String?
    var areaName: String?
    var scheduledDate: Date?
    var urls: [String]
}
```

The on-device prompt receives the raw transcript, pinned current date/timezone,
and allowed area names. It may correct speech-to-text artifacts and infer
structure, but it may not invent missing people, URLs, dates, or completion
state. The raw transcript is retained separately.

If the model is unavailable or its result fails validation, the task remains raw
and fully editable. The cleanup job can be retried from the card/task detail.

## State and components

- `AppleSpeechSession`: shared framework adapter.
- `VoiceTaskCaptureCoordinator`: hotkey → speech → raw task → cleanup.
- `VoiceTaskDrafting`: pure validation/merge rules for generated drafts.
- `VoiceTaskQuickEditController`: floating panel lifecycle and display choice.
- `VoiceTaskQuickEditView`: thin SwiftUI form bound to the task.

Refactor the existing `VoiceCaptureController` into
`VoiceTaskCaptureCoordinator`; do not leave a second competing capture
coordinator. Speech, persistence, and panel responsibilities remain separate
injected units.

## Error handling

- Missing mic/speech permission: pill explains the missing permission and offers
  System Settings.
- Assets unavailable: no recording starts; show installation/readiness state.
- Analyzer failure after speech began: preserve the best stable transcript; if
  only provisional text exists, present it in the card as an explicitly
  recoverable draft.
- Model unavailable: open the editor with raw text and mark cleanup retryable.
- Hotkey collision: surface the failed shortcut and provide a settings route.
- Save failure: keep the editor and captured text visible with Retry/Copy.

## Tests

TDD-first pure tests cover:

- Provisional results never commit a task.
- Final valid result creates exactly one raw Inbox task.
- Minimum-hold and empty-text cancellation.
- Generated-field validation and merge.
- A generated result cannot overwrite a user-revised field.
- Deterministic URL extraction and invalid URL rejection.
- Multiple captures commit/preserve the previous editor state.
- Model unavailability and retry state.
- Hotkey registration failure state.
- Pinned time/timezone date interpretation.

Injected integration tests cover speech-result mapping, asset readiness, task
insertion, and panel lifecycle. Manual smoke testing covers the real microphone,
first partial latency, notch placement, keyboard behavior, and URL editing.

## Acceptance criteria

1. `⌃⌥Space` works globally on Leon's macOS 27 beta Mac.
2. Live provisional text appears and release creates one task.
3. The task's raw transcript is preserved verbatim.
4. The notch-adjacent editor opens after capture and supports title, notes,
   multiple URLs, area, and schedule.
5. User edits win over late generated results.
6. Cleanup is performed only by the on-device Apple model.
7. Capture remains useful when cleanup is unavailable.
8. The legacy speech implementation and agent cleanup are removed only after
   migration verification.
9. `swift test` and `swift build` succeed; Leon confirms the native UI.

## Out of scope

- Arbitrary-app text insertion; see the dictation spec.
- Meeting-length capture.
- Custom spoken editing commands.
- Cloud/Codex cleanup.
- Automatic delegation or outward execution from a voice task.

## Proposed implementation slices

1. Platform/deployment update and Apple speech adapter.
2. Asset readiness, permission UI, vocabulary context, and prewarming.
3. On-device typed voice-task drafting and safe merge rules.
4. Notch-adjacent quick-edit panel.
5. Migration, telemetry-free local evaluation fixtures, and removal of the
   legacy/agent path.
