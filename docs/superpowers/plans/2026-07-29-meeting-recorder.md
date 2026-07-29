# On-Device Meeting Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record microphone plus meeting audio through headphones, produce a local two-channel transcript and Apple Intelligence digest, and approval-gate every proposed task.

**Architecture:** A pure recording state machine coordinates injected ScreenCaptureKit, incremental audio storage, transcription, and model services. SwiftData stores metadata/segments/proposals; validated relative paths point to recoverable local audio files.

**Tech Stack:** ScreenCaptureKit, AVFoundation/AVAssetWriter, SpeechAnalyzer, Foundation Models, SwiftData, SwiftUI/AppKit notch UI, XCTest.

---

### Task 1: Add CloudKit-shaped meeting models

**Files:**
- Create: `Sources/MustardKit/Models/MeetingRecord.swift`
- Create: `Sources/MustardKit/Models/MeetingTranscriptSegment.swift`
- Create: `Sources/MustardKit/Models/MeetingActionProposal.swift`
- Modify: `Sources/MustardKit/MustardContainer.swift`
- Test: `Tests/MustardTests/MeetingRecordModelTests.swift`

- [ ] **Step 1: Write failing relationship/default tests**

Assert fresh records default to preparing/pending, optional relationships decode,
segment source round-trips, proposal approval links at most one task, and audio
paths are relative.

- [ ] **Step 2: Implement models**

Use string-backed enums and optional/defaulted fields. Relationships:
`MeetingRecord.segments` cascade, `MeetingRecord.proposals` cascade,
`MeetingActionProposal.createdTask` nullify, and optional `CalendarEvent`.

- [ ] **Step 3: Register models and test**

```bash
swift test --filter MeetingRecordModelTests
```

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Models Sources/MustardKit/MustardContainer.swift Tests/MustardTests/MeetingRecordModelTests.swift
git commit -m "feat(meetings): add recorder data model" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: Implement recording lifecycle and recovery manifest

**Files:**
- Create: `Sources/MustardKit/Logic/MeetingRecordingState.swift`
- Create: `Sources/MustardKit/Meeting/MeetingRecoveryManifest.swift`
- Test: `Tests/MustardTests/MeetingRecordingStateTests.swift`
- Test: `Tests/MustardTests/MeetingRecoveryManifestTests.swift`

- [ ] **Step 1: Write failing transition tests**

Cover prepare/start/pause/resume/stop/finalize/fail/recover, reject double start,
and preserve partial state after interruption.

- [ ] **Step 2: Implement pure transitions**

```swift
public enum MeetingRecordingState: Equatable {
    case idle, preparing, recording(startedAt: Date), paused
    case finalizingAudio, finalizingTranscript, summarizing
    case ready, partial(String), failed(String)
}
```

Only explicit user confirmation may transition preparing → recording.

- [ ] **Step 3: Implement codable manifest**

Store meeting UID, exact relative directory, source file names, safe byte/sample
positions, start time, and last state. Write atomically after each durable audio
checkpoint.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingRecordingStateTests
swift test --filter MeetingRecoveryManifestTests
git add Sources/MustardKit/Logic/MeetingRecordingState.swift Sources/MustardKit/Meeting/MeetingRecoveryManifest.swift Tests/MustardTests/MeetingRecordingStateTests.swift Tests/MustardTests/MeetingRecoveryManifestTests.swift
git commit -m "feat(meetings): add recoverable recording lifecycle" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 3: Build safe incremental audio storage

**Files:**
- Create: `Sources/MustardKit/Meeting/MeetingAudioStore.swift`
- Create: `Sources/MustardKit/Meeting/MeetingAudioWriter.swift`
- Test: `Tests/MustardTests/MeetingAudioStoreTests.swift`

- [ ] **Step 1: Write failing path/finalization tests**

Test traversal rejection, exact meeting directory creation, source-track names,
atomic finalization, partial recovery, mixed output, and disk-write failure.

- [ ] **Step 2: Implement validated paths**

Resolve only:

```text
Application Support/Mustard/Recordings/<meeting-uid>/
  you.partial.caf
  meeting.partial.caf
  you.m4a
  meeting.m4a
  playback.m4a
  recovery.json
```

Reject any UID/path whose standardized URL escapes `Recordings`.

- [ ] **Step 3: Implement incremental writers**

Append 48 kHz PCM sample buffers, checkpoint the manifest, finalize each source,
then mix into AAC `.m4a`. Preserve partial files on failure.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingAudioStoreTests
git add Sources/MustardKit/Meeting/MeetingAudioStore.swift Sources/MustardKit/Meeting/MeetingAudioWriter.swift Tests/MustardTests/MeetingAudioStoreTests.swift
git commit -m "feat(meetings): persist recoverable audio tracks" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 4: Capture system audio and microphone

**Files:**
- Create: `Sources/MustardKit/Meeting/MeetingAudioCapture.swift`
- Create: `Sources/MustardKit/Meeting/ScreenCaptureMeetingAudio.swift`
- Test: `Tests/MustardTests/MeetingAudioCaptureTests.swift`

- [ ] **Step 1: Write failing routing tests**

Stub sample outputs and assert `.audio` routes to Meeting, `.microphone` routes
to You, timestamps share one clock, missing source requires confirmation, and
device/source change pauses the affected stream.

- [ ] **Step 2: Define the injected capture contract**

```swift
public protocol MeetingAudioCapturing: Sendable {
    func availableSources() async throws -> [MeetingAudioSource]
    func start(source: MeetingAudioSource) async throws -> AsyncThrowingStream<MeetingAudioSample, Error>
    func pause() async throws
    func resume() async throws
    func stop() async throws
}
```

- [ ] **Step 3: Implement ScreenCaptureKit**

Use `SCContentFilter`, `SCStreamConfiguration.capturesAudio = true`,
`captureMicrophone = true`, 48 kHz, and outputs `.audio` and `.microphone`.
Do not add a `.screen` output or store video frames. Surface when a Chrome app
filter can include other tab audio.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingAudioCaptureTests
swift build
git add Sources/MustardKit/Meeting/MeetingAudioCapture.swift Sources/MustardKit/Meeting/ScreenCaptureMeetingAudio.swift Tests/MustardTests/MeetingAudioCaptureTests.swift
git commit -m "feat(meetings): capture call and microphone audio" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 5: Merge two-source transcripts

**Files:**
- Create: `Sources/MustardKit/Logic/MeetingTranscriptMerge.swift`
- Create: `Sources/MustardKit/Meeting/MeetingTranscriptionService.swift`
- Test: `Tests/MustardTests/MeetingTranscriptMergeTests.swift`

- [ ] **Step 1: Write failing merge tests**

Pin overlapping and adjacent You/Meeting segments, equal timestamps, provisional
replacement, sequential post-processing fallback, and stable segment IDs.

- [ ] **Step 2: Implement deterministic merge**

Sort by start, end, source tie-break, and stable ID. Persist only final segments;
keep user correction separate from raw text.

- [ ] **Step 3: Implement live/sequential fallback**

Try two `AppleSpeechSession`s. On `insufficientResources`, continue recording,
transcribe one live, then process the other audio file after Stop and merge.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingTranscriptMergeTests
git add Sources/MustardKit/Logic/MeetingTranscriptMerge.swift Sources/MustardKit/Meeting/MeetingTranscriptionService.swift Tests/MustardTests/MeetingTranscriptMergeTests.swift
git commit -m "feat(meetings): build two-source transcripts" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 6: Add manual notch recording controls

**Files:**
- Create: `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift`
- Create: `Sources/MustardKit/Views/MeetingRecordingNotchView.swift`
- Modify: `Sources/MustardKit/Views/NotchSurface.swift`
- Modify: `Sources/Mustard/MustardApp.swift`
- Test: `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Test explicit confirmation, duplicate prevention, pause/resume, stop pipeline,
permission failure, single-source confirmation, disk pressure, device change,
and recovery on launch.

- [ ] **Step 2: Implement coordinator**

Sequence permission/source selection → record creation → capture/writers →
stop/finalization/transcription. Save state before and after each impure edge.

- [ ] **Step 3: Add notch UI**

Add Start Meeting, source chooser, consent confirmation, red recording
indicator, title/provider, timer, pause/resume, and Stop. Reuse Theme everywhere
except the intentionally dark notch palette.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingCaptureCoordinatorTests
swift build
git add Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift Sources/MustardKit/Views/MeetingRecordingNotchView.swift Sources/MustardKit/Views/NotchSurface.swift Sources/Mustard/MustardApp.swift Tests/MustardTests/MeetingCaptureCoordinatorTests.swift
git commit -m "feat(meetings): add manual notch recorder" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 7: Generate evidence-backed on-device digests

**Files:**
- Create: `Sources/MustardKit/Logic/MeetingDigestChunker.swift`
- Create: `Sources/MustardKit/Meeting/MeetingDigestService.swift`
- Create: `Sources/MustardKit/Voice/Prompts/meeting-digest-27.txt`
- Test: `Tests/MustardTests/MeetingDigestChunkerTests.swift`
- Test: `Tests/MustardTests/MeetingDigestServiceTests.swift`

- [ ] **Step 1: Write failing chunk/evidence tests**

Cover runtime context budgets, silence boundaries, oversized single segment,
multi-pass reduction, nonexistent evidence IDs, unsupported locale, and local
model unavailable.

- [ ] **Step 2: Define guided outputs**

```swift
@Generable struct GeneratedMeetingAction {
    var title: String
    var owner: String?
    var dueISO8601: String?
    var evidenceSegmentIDs: [String]
}

@Generable struct GeneratedMeetingDigest {
    var summary: String
    var decisions: [String]
    var unresolvedQuestions: [String]
    var actions: [GeneratedMeetingAction]
}
```

- [ ] **Step 3: Implement hierarchical generation**

Use `tokenCount(for:)`/`contextSize`, fresh sessions per chunk, validated segment
IDs, then one or more reduction sessions. Store prompt version and OS build.
Never create proposals without valid evidence.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingDigest
git add Sources/MustardKit/Logic/MeetingDigestChunker.swift Sources/MustardKit/Meeting/MeetingDigestService.swift Sources/MustardKit/Voice/Prompts/meeting-digest-27.txt Tests/MustardTests/MeetingDigestChunkerTests.swift Tests/MustardTests/MeetingDigestServiceTests.swift
git commit -m "feat(meetings): create on-device meeting digests" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 8: Build meeting review, playback, and task approval

**Files:**
- Create: `Sources/MustardKit/Views/MeetingReviewView.swift`
- Create: `Sources/MustardKit/Views/MeetingTranscriptView.swift`
- Create: `Sources/MustardKit/Views/MeetingActionProposalView.swift`
- Create: `Sources/MustardKit/Logic/MeetingActionApproval.swift`
- Modify: `Sources/MustardKit/Views/RootView.swift`
- Test: `Tests/MustardTests/MeetingActionApprovalTests.swift`

- [ ] **Step 1: Write failing approval tests**

Approve creates exactly one linked Inbox task, second approval is idempotent,
reject creates none, evidence survives, and title/date/area edits apply.

- [ ] **Step 2: Implement approval**

Use an injected `ModelContext` operation and proposal UID idempotency. Set task
`source = "meeting-recording"`, context/link to the meeting, and no outward
action.

- [ ] **Step 3: Build review UI**

Add mixed playback scrubber, timestamp jump, transcript search, corrected-text
editing, summary/decisions/questions, proposal edit/approve/reject, and retry
states. Selecting evidence seeks playback and highlights the segment.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingActionApprovalTests
swift build
git add Sources/MustardKit/Views/MeetingReviewView.swift Sources/MustardKit/Views/MeetingTranscriptView.swift Sources/MustardKit/Views/MeetingActionProposalView.swift Sources/MustardKit/Logic/MeetingActionApproval.swift Sources/MustardKit/Views/RootView.swift Tests/MustardTests/MeetingActionApprovalTests.swift
git commit -m "feat(meetings): review recordings and approve tasks" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 9: Add calendar/app meeting suggestions

**Files:**
- Create: `Sources/MustardKit/Logic/MeetingDetection.swift`
- Create: `Sources/MustardKit/Meeting/MeetingAppSignals.swift`
- Create: `Sources/MustardKit/Views/MeetingStartPromptView.swift`
- Modify: `Sources/Mustard/MustardApp.swift`
- Test: `Tests/MustardTests/MeetingDetectionTests.swift`

- [ ] **Step 1: Write failing scoring/dedupe tests**

Cover Google Meet+Chrome, Zoom, Teams, Slack Huddle, calendar-only, app-only,
dismissed event, already-recording event, fallback identity, pinned UTC time,
and never-auto-start.

- [ ] **Step 2: Implement pure detection**

Return a ranked `MeetingSuggestion` only; the result has no method that can start
capture. Deduplicate by event UID, else provider plus start-window identity.

- [ ] **Step 3: Implement signals and prompt**

Read injected calendar events plus running app/window metadata. Prompt with
Start, Not now, and Don't prompt for this event. Starting calls the same manual
confirmation path.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingDetectionTests
git add Sources/MustardKit/Logic/MeetingDetection.swift Sources/MustardKit/Meeting/MeetingAppSignals.swift Sources/MustardKit/Views/MeetingStartPromptView.swift Sources/Mustard/MustardApp.swift Tests/MustardTests/MeetingDetectionTests.swift
git commit -m "feat(meetings): suggest supported calls" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 10: Add retention, Trash deletion, and export

**Files:**
- Create: `Sources/MustardKit/Logic/MeetingRetention.swift`
- Create: `Sources/MustardKit/Meeting/MeetingExportService.swift`
- Modify: `Sources/MustardKit/Meeting/MeetingAudioStore.swift`
- Modify: `Sources/MustardKit/Views/MeetingReviewView.swift`
- Test: `Tests/MustardTests/MeetingRetentionTests.swift`
- Test: `Tests/MustardTests/MeetingExportServiceTests.swift`

- [ ] **Step 1: Write failing retention tests**

Pin now/timezone; test 29/30/31 days, pinned exemption, already-missing audio,
path traversal, Trash failure, metadata preservation, and retry.

- [ ] **Step 2: Implement exact cleanup**

Delete Audio validates the meeting directory, removes audio, then updates
metadata. Delete Meeting moves that exact directory to system Trash first and
only then deletes SwiftData. A failure keeps metadata and path.

- [ ] **Step 3: Implement export**

Export mixed `.m4a` plus Markdown containing metadata, summary, decisions,
actions, and timestamped transcript. Use a user-selected destination and never
overwrite without confirmation.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MeetingRetentionTests
swift test --filter MeetingExportServiceTests
git add Sources/MustardKit/Logic/MeetingRetention.swift Sources/MustardKit/Meeting/MeetingExportService.swift Sources/MustardKit/Meeting/MeetingAudioStore.swift Sources/MustardKit/Views/MeetingReviewView.swift Tests/MustardTests/MeetingRetentionTests.swift Tests/MustardTests/MeetingExportServiceTests.swift
git commit -m "feat(meetings): retain and export recordings safely" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 11: Run the real macOS 27 meeting matrix

**Files:**
- Create: `docs/validation/2026-07-29-meeting-recorder.md`
- Modify: `README.md`
- Modify: `docs/build-order.md`

- [ ] **Step 1: Test providers with headphones**

Record exact results for Google Meet/Chrome, Zoom, Teams, and Slack Huddles:
system track, mic track, playback mix, You/Meeting transcript alignment,
suggestion behavior, and permission prompts.

- [ ] **Step 2: Test recovery and retention**

Exercise pause/resume, source change, app closure, forced Mustard termination,
disk failure simulation, partial recovery, pin, 30-day cleanup, Trash failure,
and export.

- [ ] **Step 3: Evaluate Apple model output**

For representative short and long meetings, record OS build, prompt version,
context size, summary factual coverage, evidence validity, action precision, and
false proposals. All actions still require approval.

- [ ] **Step 4: Final verification and commit**

```bash
swift test
swift build
./build-app.sh
git diff --check
git add docs/validation/2026-07-29-meeting-recorder.md README.md docs/build-order.md
git commit -m "test(meetings): validate local recorder workflow" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```
