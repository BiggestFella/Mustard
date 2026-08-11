# Fresh-context review — BAK-332 audio-source parity

Branch `agent/bak-332-audio-source-parity`, diff base `origin/main` (2 commits:
`110df7a`, `75cb4ff`). Reviewed with no prior context; all claims below were
verified directly against the code, not taken from `task.md`.

## Standards Review — PASS

- Decision logic lives in `Sources/MustardKit/Logic/MeetingSourceParity.swift`
  as a new, pure, unit-tested type — matches the repo's separation rule
  (`CLAUDE.md`: "anything with a decision in it ... goes in `Logic/`").
- `MeetingCaptureCoordinator.swift` (impure orchestration layer) only calls
  into the pure unit and reuses the existing `errorMessage` field — no schema
  change, no new `@Model` property.
- Diff is narrowly scoped: 2 source files + 2 test files + run artifacts.
  No drive-by refactors, no view changes.
- Style matches local convention (BAK-tagged comments, `voiceLog` usage
  pattern identical to existing `fail()`/`interrupt()`/`applyDigestFailure()`).

## Spec Review — PASS

All four acceptance criteria verified against actual behavior, not just
claimed:

1. **Start/append failure surfaced.** `MeetingCaptureCoordinator.swift:137-148`
   — the route closure now does `try`/`catch` instead of `try?`; on first
   failure per channel (`writerFailureLogged.insert(channel).inserted`) it
   emits `voiceLog.error`. Confirmed there is no separate "per-source start"
   step to gate on — `MeetingAudioWriter.trackFile` (MeetingAudioWriter.swift:59-77)
   opens the channel's file lazily on first `append`, so "surfaced at start
   time" is correctly implemented as "surfaced on first append failure,"
   which is the earliest point failure is knowable in this architecture.
2. **Finalize parity.** `MeetingSourceParity.evaluate` + `applySourceParity`
   (MeetingCaptureCoordinator.swift:427-444) flags a channel only when
   transcript evidence exists but no audio finalized, sets
   `record.errorMessage` naming the channel, and never touches `status`,
   `audioFinalized`, the persisted transcript, or the other channel's file.
   Confirmed via `test_micWriterNeverWritesAFile_whileTranscriptionSucceeds_flagsParity_keepsRecordingAndTranscript`
   (passes) — `record.status == .ready`, `youAudioPath == nil`,
   `meetingAudioPath` intact, transcript segment persisted, `errorMessage`
   names "Microphone".
3. **Manifest honesty.** Read `MeetingAudioWriter.checkpoint()`
   (MeetingAudioWriter.swift:83-100): it maps over `trackFiles`, which a
   channel only enters after a *successful* `AVAudioFile(forWriting:)` call
   in `trackFile` (MeetingAudioWriter.swift:59-77, cached on success). So
   `recovery.json` genuinely never lists a source that didn't open — the
   builder's claim holds against the actual code, and `MeetingAudioWriter.swift`
   is untouched by this diff (confirmed via `git diff --stat`).
4. **Regression test.** `test_micWriterNeverWritesAFile_whileTranscriptionSucceeds_flagsParity_keepsRecordingAndTranscript`
   drives a *real* mismatched-sample-rate buffer through the actual
   `MeetingAudioWriter.append` guard (MeetingAudioWriter.swift:48-53), not a
   mock — confirmed red-first in `verification.md` (reverting the coordinator
   fix flips the assertion from pass to a concrete `nil` vs message failure).

No unrequested behavior added; out-of-scope items (view files, recovery
manifest schema, digest logic) are untouched.

## Extra-scrutiny items — all verified, no blocker

1. **Status-vs-errorMessage deviation.** Both cited claims check out in
   `MeetingReviewView.swift`: `statusBadge` renders `.partial` as "Interrupted"
   in warning color (line 131), and `digestSection` gates both "Generate
   digest" (line 331) and "Retry digest" (line 342) on `meeting.status == .ready`.
   `errorMessage` renders unconditionally in the header (`header(_:)`, line
   190) regardless of `status` — so the message does surface for a `.ready`
   meeting. Checked every writer of `errorMessage`
   (`MeetingCaptureCoordinator.swift:324,347,355,441`,
   `MeetingReviewView.swift:284`) for a clobber/collision: `fail()` and
   `interrupt()` only run on failure/interruption paths that `return` before
   `applySourceParity` is ever reached in the same `stop()` call, and
   `recoverOnLaunch()` explicitly skips any record whose `status == .ready`
   (`guard record.status != .ready else { continue }`, line 321) — so it can
   never touch a record that `applySourceParity` already stamped. No
   read/write conflict found on any path.
2. **Hot-path change.** `MeetingAudioCapture.route` is typed
   `@escaping @MainActor (MeetingSegmentSource, MeetingAudioSample) -> Void`
   (MeetingAudioCapture.swift:63) — synchronous, non-throwing, always
   main-actor. The catch block only performs a `Set<MeetingSegmentSource>.insert`
   (cheap, bounded to 2 possible values) and, only on the first failure per
   channel, one `voiceLog.error` string interpolation — no per-buffer
   allocation in the steady state. `transcriptionFeed?.yield(...)` is
   unconditional on the line after the do/catch (line 147), so a writer
   failure never removes the buffer from the transcription feed.
3. **`MeetingSourceParity.evaluate` semantics.** Confirmed via code and the
   8-test suite: iterating over `startedSources` only means a channel that
   somehow transcribed without starting is structurally excluded (not
   representable via the current call site, and even if it were, the
   function's loop wouldn't visit it since it isn't in `startedSources`); a
   started channel with no transcript and no audio (quiet meeting) fails the
   `transcribedChannels.contains(channel)` guard and is correctly never
   flagged (`test_emptyTranscript_audioAlsoMissing_isNotFlagged_noEvidenceEitherWay`).
4. **`stampAudioPaths` truthfulness.** `stampAudioPaths`
   (MeetingCaptureCoordinator.swift:446-456) only sets a path when
   `FileManager.default.fileExists(atPath: url.path)` is true — `applySourceParity`
   runs immediately after and reads `record.youAudioPath`/`meetingAudioPath`,
   which are therefore never a lie about what's on disk.

One pre-existing, out-of-scope observation (non-blocking, not part of
BAK-332's acceptance criteria): `transcription.append` in the pump
(MeetingCaptureCoordinator.swift:127) still swallows failures via `try?`,
unchanged by this diff. The brief explicitly scoped this task to "surfacing,
not re-plumbing" the writer side; flagging only as a possible future
follow-up, not a blocker here.

## Risk Review — PASS, medium confirmed

Per `.agent-loop/risk.yml`, `Sources/` → medium, `Tests/` → low; no path
matches any `high` pattern (`ClaudeRunner`, `TrustPolicy`,
`RecommendationAction`, auth/secret/deployment paths — all untouched,
confirmed via `git diff --stat`). No outward action (no push, no PR, no
tags/secrets/force-push) — matches the risk-report's claim. Risk class
(medium) matches the actual diff: additive pure logic + a narrow,
non-destructive coordinator change reusing an existing field.

## Test Review — PASS

Ran directly, not just read:

- `swift test --filter MeetingSourceParityTests`: **8/8 pass**, 0 failures.
- `swift test --filter MeetingCaptureCoordinatorTests`: **18/18 pass**
  (16 pre-existing + 2 new), 0 failures.
- `swift test` (full suite): **1549 tests, 1 skipped, 0 failures**, exit 0 —
  matches `verification.md`'s claimed count exactly (1539 baseline + 10 new).
- `swift build`: exit 0.

Tests cover observable behavior through the public interface
(`MeetingSourceParity.evaluate`, and the coordinator's `stop()` via a real
format-mismatch buffer against the real `MeetingAudioWriter.append` guard —
not a mocked writer). Red-first is documented and independently plausible
(reverting the coordinator change and re-running the regression test would
flip the `errorMessage` assertion from a message to `nil`). The 1 skip is
pre-existing and unrelated to this change (present in the stated baseline
count too).

## Commands run

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingSourceParityTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```

All exit 0.

## Findings

None blocking. One non-blocking, out-of-scope observation noted above
(pre-existing `try?` on the transcription-append pump — not part of this
ticket's acceptance criteria).

VERDICT: mergeable
