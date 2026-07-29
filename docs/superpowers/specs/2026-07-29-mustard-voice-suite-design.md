# Mustard Voice Suite — Umbrella Design

**Date:** 2026-07-29
**Status:** Approved (design), pending written spec review → implementation plans
**Owner:** Leon
**Target:** macOS 26 minimum, developed and validated first on Leon's macOS 27 beta Mac

## Goal

Make voice a first-class input and evidence source in Mustard while keeping the
experience local-first:

1. Upgrade voice-task capture to Apple's current speech stack and open a fast
   editor after every capture.
2. Add push-to-talk dictation into the active text field in any compatible Mac
   app.
3. Add a Granola-style meeting recorder that captures both sides of a call,
   transcribes it, creates an on-device meeting digest, and proposes tasks for
   Leon's approval.

These are three separately shippable features with one shared foundation. They
receive separate specs, plans, Linear epics, and implementation sequences:

- [Modern voice-task capture](2026-07-29-modern-voice-task-capture-design.md)
- [System-wide dictation](2026-07-29-system-wide-dictation-design.md)
- [Meeting recorder](2026-07-29-meeting-recorder-design.md)

## Product decisions

- Raise Mustard's deployment floor from macOS 14 to macOS 26.
- Use macOS 27 capabilities at runtime when available; do not hard-code a model
  version or context size.
- Remove the legacy `SFSpeechRecognizer` implementation after the modern speech
  path passes the agreed smoke tests.
- Use Apple `SpeechAnalyzer` + `SpeechTranscriber` for transcription.
- Use Apple's on-device Foundation Models framework for voice-task cleanup and
  meeting summaries. Voice-suite v1 has no Codex, Private Cloud Compute, or
  third-party model fallback.
- Preserve raw transcripts as evidence. Generated fields never silently replace
  user edits.
- Meeting action items always require Leon's approval in v1.
- Meeting capture never starts silently.

## Shared architecture

Create a small shared voice foundation in `MustardKit`, consumed by three
independent feature coordinators:

```text
                     ┌────────────────────────────┐
 microphone/audio ─▶ │ MustardVoiceCore           │
                     │ AppleSpeechSession         │
                     │ OnDeviceLanguageService    │
                     │ VoiceAssetReadiness        │
                     └─────────────┬──────────────┘
                                   │ typed events/results
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
     VoiceTaskCapture      SystemDictation       MeetingCapture
     quick-edit card       active-field insert   record/review/tasks
```

### `AppleSpeechSession`

A focused adapter around Apple's Speech framework:

- `SpeechAnalyzer` owns each analysis session.
- `SpeechTranscriber` supplies provisional and final transcript results.
- `SpeechDetector` supplies voice-activity/silence boundaries where it improves
  segmentation.
- Reporting options request the available confidence and audio-time metadata.
- `AnalysisContext` carries Mustard areas, project names, contacts, and recent
  user vocabulary.
- `AssetInventory` checks and installs the required locale assets.
- Analyzer preparation/model retention is used where supported and justified by
  capture latency and energy testing.
- Results are normalized into Mustard value types so feature logic and tests do
  not depend directly on framework objects.

The implementation must avoid the name collision with Mustard's current local
`SpeechTranscriber` class; the Mustard adapter is named `AppleSpeechSession`.

### `OnDeviceLanguageService`

A narrow adapter around the Foundation Models framework:

- Uses the macOS 27 `SystemLanguageModel` automatically selected by the OS.
- Checks `availability`, supported locale, `contextSize`, and exposed model
  capabilities at runtime.
- Uses guided/structured generation for typed outputs.
- Uses concise prompts selected by OS/model release band (`26.0–26.3`, `26.4`,
  `27.0+`) following Apple's availability-check guidance.
- Records Mustard's prompt version and the macOS build with generated results;
  Apple does not expose a general runtime model-version identifier.
- Splits work into separate sessions when it exceeds the reported context
  budget.
- Prewarms only near likely use and releases retained resources when idle.

If Apple Intelligence is disabled, unsupported, downloading, or temporarily
unavailable, capture and transcription continue. Language work becomes a
retryable local job; it never falls through to a network model.

## Permissions

Add a Voice Setup surface that explains and reports these permissions
independently:

- Microphone
- Speech Recognition
- Accessibility, for system-wide text insertion
- System Audio / Screen Recording, for meeting audio
- Calendar, for meeting-start suggestions when live calendar data is available

Permission denial degrades only the affected feature. Mustard must show the
exact missing permission and a route to the appropriate System Settings pane.

## Privacy and evidence

- Short-form and meeting transcription is on-device.
- Voice-task cleanup and meeting summaries are on-device.
- Audio and transcripts remain in Mustard's local storage.
- Raw voice-task text and stable meeting transcript segments are immutable
  evidence; corrections and generated interpretations are stored separately.
- Generated decisions/action items link back to supporting transcript
  timestamps.
- Meeting recording presents a persistent indicator and consent reminder.
- The app never records a meeting without a user confirmation.

## Cross-feature failure rules

- Never lose captured text because enrichment failed.
- Never overwrite a field Leon edited while an on-device result was pending.
- Never insert text into secure/password fields.
- Never create a meeting-derived task without approval in v1.
- Never delete a pinned meeting recording through retention cleanup.
- A process crash or audio-device change must leave a recoverable partial
  meeting when audio has already been written.
- Hotkey registration failures must be visible; they may not fail silently.

## Shared testing strategy

Decision logic lives in `Logic/` or pure feature units and is written TDD-first.
Framework edges are injected:

- Speech analyzer/session
- Speech asset inventory
- Foundation model/session
- Audio capture and file writer
- Accessibility focus and text insertion
- Calendar/app meeting detection
- Clock and retention scheduler

Tests pin time and timezone. Model tests use deterministic typed fixtures rather
than expecting the live Apple model to produce byte-identical prose. A separate
evaluation fixture set measures whether real model output contains required,
evidence-backed facts.

Because Leon runs a beta OS, each macOS beta update receives a manual smoke pass:

1. Voice-task first partial and final result.
2. System-wide insertion into native and browser fields.
3. Headphone meeting capture with system audio plus microphone.
4. On-device summary availability and structured output.

Views are verified by `swift build`, app launch, and Leon's eye. Completion still
requires the whole `swift test` suite and `swift build`.

## Delivery order

1. Shared Apple speech and on-device language foundation.
2. Modern voice-task capture and quick-edit card.
3. System-wide dictation.
4. Meeting capture foundation and manual notch control.
5. Automatic meeting detection.
6. Meeting transcript, summary, review, task approval, playback, and retention.

Each numbered feature spec becomes its own implementation plan. This keeps the
meeting recorder's storage and lifecycle risks from blocking the two shorter
voice workflows.

## Out of scope for the suite v1

- Cloud or Codex processing of voice-suite content.
- Silent/automatic meeting recording.
- Guaranteed naming of individual remote speakers.
- Video or screen-image recording.
- Multi-user sharing or collaborative meeting notes.
- Automatic creation or outward execution of meeting action items.
- iOS capture surfaces.

## Source references

- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/Speech/SpeechAnalyzer)
- [Apple SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/)
- [Apple Foundation Models updates](https://developer.apple.com/documentation/Updates/FoundationModels)
- [Updating prompts for new model versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)
- [Managing the Foundation Models context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
