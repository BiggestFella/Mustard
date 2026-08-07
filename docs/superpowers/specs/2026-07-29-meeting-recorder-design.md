# On-Device Meeting Recorder — Design

**Date:** 2026-07-29
**Status:** Approved (design), pending written spec review → implementation plan
**Parent:** [Mustard Voice Suite](2026-07-29-mustard-voice-suite-design.md)

## Goal

Add a Granola-style meeting workflow to Mustard: capture both sides of a meeting
even when Leon wears headphones, produce a searchable local transcript and
on-device digest, and present evidence-backed action items for approval.

V1 supports Google Meet in Chrome, Zoom, Microsoft Teams, and Slack Huddles.
Manual recording remains available for any other meeting source.

## Product behavior

### Start

Recording can begin in two ways:

- **Manual:** Start Meeting from the expanded notch.
- **Suggested:** Mustard detects a likely meeting from a calendar event plus a
  supported conferencing app/window and displays a prompt.

Suggested recording never starts automatically. The prompt names the event/app
and offers **Start**, **Not now**, and **Don't prompt for this event**.

Detection signals:

- Calendar event start window and conference URL/provider.
- Running/active Zoom or Teams app/window.
- Active Chrome window associated with a Google Meet event/link.
- Active Slack window consistent with a Huddle.

Signals produce a confidence-ranked suggestion; none are treated as recording
consent. Slack Huddle and browser-tab detection are best-effort because those
apps may not expose stable public state. A missed suggestion does not affect
manual capture.

### During

The notch displays:

- Recording indicator
- Meeting title/provider
- Elapsed time
- Pause/Resume
- Stop

Capture continues while Mustard's main window is hidden. A persistent visible
recording indicator and consent reminder remain present. Device changes or
interruption show a recoverable warning without silently switching to the wrong
input.

### After

Stopping opens a meeting review surface with progressive states:

1. Finalizing audio
2. Finalizing transcript
3. Creating on-device digest
4. Ready for review

The final page contains:

- Audio playback and scrubber
- Timestamped, searchable transcript
- Editable meeting notes
- Summary
- Decisions
- Unresolved questions
- Proposed action items with owner/date and evidence timestamps
- Calendar and conference links
- Export and delete controls

Action items remain proposals until Leon approves each one. Approval creates or
links a Mustard task. Rejecting a proposal preserves the meeting record but
creates no task.

## Audio capture

Use ScreenCaptureKit to capture two synchronized sources:

- `.audio`: selected app/system meeting audio, captured before output routing so
  it works when Leon listens through headphones.
- `.microphone`: Leon's selected built-in, USB, or headset microphone.

V1 records audio only; no video frames or screen images are retained. Configure
48 kHz audio where supported. Write source tracks incrementally to local
temporary containers and finalize them into:

- A **You** microphone track
- A **Meeting** system-audio track
- A mixed playback `.m4a`

The source tracks allow reliable top-level attribution between Leon and remote
meeting audio. V1 does not promise individual identification of remote speakers.
Names mentioned or inferred in text may appear as editable suggestions, never
as verified speaker identity.

For app-filtered capture, Mustard tells Leon what source is selected. Capturing
Chrome may include audio from other Chrome tabs when macOS cannot isolate the
meeting tab; the recording UI warns when the filter has that scope.

Screen/System Audio and Microphone permissions are checked before starting.

## Live and deferred transcription

Prefer separate `AppleSpeechSession` instances for microphone and meeting audio
so stable segments retain **You** versus **Meeting** attribution. The two streams
share a synchronization clock and are merged by time for display.

Apple limits concurrent analyzer resources based on the hardware and active
configuration. If two live analyzers cannot run reliably:

1. Keep recording both audio tracks.
2. Transcribe one source live for feedback.
3. Transcribe the other source sequentially after Stop.
4. Merge stable timestamped segments before summary generation.

Recording is therefore not dependent on live transcription capacity.

`SpeechDetector` supplies silence/voice boundaries where useful.
`AnalysisContext` includes calendar participants, event title, Mustard areas,
known projects, and recent vocabulary. Raw stable transcript text is immutable;
user corrections are stored separately.

## On-device digest

Use `SystemLanguageModel` through `OnDeviceLanguageService`. The service queries
the installed macOS 27 model's availability, supported language, and context
size at runtime. Prompt selection uses the OS availability bands Apple documents
for its model releases because the framework does not expose a general runtime
model-version identifier.

Long meetings use hierarchical structured summarization:

1. Partition stable transcript segments on semantic/silence boundaries within a
   conservative token budget.
2. In independent sessions, extract a typed chunk digest containing topics,
   decisions, action candidates, owners, dates, unresolved questions, and source
   segment IDs.
3. Validate every referenced segment and discard unsupported evidence links.
4. Combine chunk digests in one or more fresh sessions into the meeting digest.
5. Materialize action proposals only when they retain valid supporting segment
   IDs.

Prompts are concise and versioned by Mustard, with the prompt version and macOS
build stored on the result. Evaluation fixtures are rerun when macOS changes the
installed model. The final summary remains editable; generated output is never
treated as canonical over the transcript.

macOS 27's `LanguageModelSession.DynamicProfile` is not required for v1: the
digest is a bounded structured-generation pipeline without model tools or an
agent loop. It may be evaluated later only if the measured digest quality or
latency benefits; using every new API is not itself a requirement.

If Apple Intelligence is unavailable or the meeting language is unsupported,
the meeting remains recorded and transcribed. Digest generation is marked
locally retryable. V1 has no network fallback.

## Persistence

### SwiftData

`MeetingRecord`:

- Stable UID
- Title/provider/status
- Start/end timestamps
- Calendar-event relationship/link
- Conference URL
- Capture source metadata
- Audio relative paths and finalization state
- Summary/digest status
- Mustard prompt version and macOS build
- Retention deadline
- Pinned flag
- Error/recovery metadata

`MeetingTranscriptSegment`:

- Stable UID and meeting relationship
- Source channel (`you` or `meeting`)
- Start/end audio time
- Stable raw text
- User-corrected text, optional
- Confidence, optional

`MeetingActionProposal`:

- Meeting relationship
- Proposed title/notes/owner/date/area
- Supporting transcript-segment IDs
- State: pending, approved, rejected
- Created task relationship, optional

All new persisted fields follow the project's CloudKit-shaped optional/default
rules even though sync is not part of this feature.

### Files

Audio is not stored as SwiftData blobs. It lives under a per-meeting directory
inside Mustard's Application Support container. SwiftData stores validated
relative paths only.

Writes use temporary files plus atomic finalization. A small recovery manifest
is updated as chunks are safely written so a crash leaves a discoverable partial
meeting.

## Retention, playback, export, deletion

- Default audio retention is 30 days from meeting end.
- Transcript, digest, notes, and task links remain after automatic audio
  deletion.
- Pinning a recording exempts it from automatic cleanup.
- Manual Delete Audio removes audio while preserving notes/transcript after
  confirmation.
- Delete Meeting first moves the exact per-meeting audio directory to the system
  Trash, then removes its SwiftData metadata/transcript. If Trash fails, Mustard
  keeps the meeting record and reports the error rather than orphaning files.
- Export can produce the mixed audio file plus a Markdown or plain-text meeting
  document with timestamps.
- The retention sweep verifies that a path belongs to the exact meeting
  directory before deletion.

## Detection and calendar integration

Define `MeetingDetection` as pure scoring over injected signals rather than
placing heuristics in the view:

- Event timing
- Conference provider/link
- Running app/window signal
- Previous dismissal for the event
- Existing active/finished meeting record

Only one prompt may be active. Mustard deduplicates by calendar event UID or a
fallback provider/time identity. If live calendar sync is unavailable, app
detection can still suggest a generic meeting and manual capture always works.

## Failure and recovery

- Permission denied: recording does not start; show the exact missing grant.
- System stream unavailable: do not create a microphone-only recording without
  explicit confirmation.
- Microphone unavailable: do not create a system-only recording without
  explicit confirmation.
- Device/app source changes: pause affected capture, preserve written audio, and
  ask Leon to resume with a selected source.
- Disk pressure: stop safely, finalize written chunks, and explain the failure.
- Process crash: recover manifest, partial audio, and meeting metadata on next
  launch.
- Transcription/model failure: preserve audio and completed transcript segments;
  expose retry.
- Duplicate meeting detection: focus the existing recording rather than start a
  second session.
- Retention failure: leave metadata/path intact and retry later; never mark
  missing audio until deletion is verified.

## Tests

TDD-first pure tests cover:

- Detection scoring/deduplication for Meet, Zoom, Teams, and Slack Huddles.
- Suggested capture never transitions to recording without confirmation.
- Recording state machine: prepare/start/pause/resume/stop/finalize/recover.
- Clock-aligned merge of You/Meeting transcript segments.
- Context-budget chunking and hierarchical digest assembly.
- Rejection of action evidence referencing nonexistent segments.
- Approval creates exactly one linked task; rejection creates none.
- 30-day retention, pinned exemption, path validation, and retry.
- Crash manifest recovery and partial-meeting states.
- Permission and device-change degradation.
- Pinned time/timezone calendar matching.

Injected integration tests cover ScreenCaptureKit sample routing, audio-writer
finalization, model fixture mapping, SwiftData relationships, and export.

Manual acceptance matrix:

- Google Meet in Chrome with headphones
- Zoom with headphones
- Microsoft Teams with headphones
- Slack Huddle with headphones
- Built-in and headset microphone
- Manual capture for an unsupported source
- Pause/resume, device change, app closure, and forced app restart
- Playback alignment and transcript timestamp navigation

## Acceptance criteria

1. Leon can manually start/stop from the notch.
2. Calendar/app detection prompts for Meet, Zoom, Teams, and Slack Huddles
   without silently recording.
3. System meeting audio and Leon's microphone are both captured while headphones
   are used.
4. A recoverable recording survives an interruption or process restart.
5. Transcript segments distinguish You from Meeting and remain searchable.
6. The on-device Apple model produces an editable, evidence-linked digest.
7. Every action item requires approval and creates at most one task.
8. Audio defaults to local 30-day retention; pin/delete/export behave as
   specified.
9. No audio, transcript, or digest is sent to a cloud model.
10. `swift test` and `swift build` succeed; Leon validates native UI and the
    manual matrix.

## Out of scope

- Silent or automatic recording.
- Video/screen capture storage.
- Guaranteed individual remote-speaker diarization.
- Cloud, Codex, or Private Cloud Compute summarization.
- Automatic outward actions or task creation.
- Shared/collaborative meeting workspaces.
- Mobile meeting capture.

## Proposed implementation slices

1. Meeting models, storage layout, state machine, and recovery manifest.
2. ScreenCaptureKit dual-source recording and manual notch controls.
3. Two-source transcription and timestamp merge.
4. Meeting review/playback/transcript surface.
5. On-device hierarchical digest and action approval.
6. Calendar/app detection for Meet, Zoom, Teams, and Slack Huddles.
7. Retention, pinning, export, deletion, and beta-OS hardening.
