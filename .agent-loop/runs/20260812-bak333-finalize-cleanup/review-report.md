# Fresh-context review — BAK-333 finalize cleanup

Branch `agent/bak-333-finalize-cleanup`, diff base `origin/main` (2 commits:
`61a4d9a`, `cc66b60`). No prior context on this task; everything below was
verified directly against the diff, the referenced source, and live command
runs — not the task's own claims.

## Deletion trace (highest scrutiny — item 1)

Read `MeetingAudioFile` (`Sources/MustardKit/Meeting/MeetingAudioStore.swift:14-20`)
and the `MeetingSegmentSource` → `MeetingAudioFile` mapping
(`Sources/MustardKit/Meeting/MeetingAudioWriter.swift:168-184`):

```
youPartial = "you.partial.caf"   meetingPartial = "meeting.partial.caf"
you        = "you.m4a"           meeting        = "meeting.m4a"
.you.partialTrack -> .youPartial     .you.finalTrack -> .you
.meeting.partialTrack -> .meetingPartial   .meeting.finalTrack -> .meeting
```

`MeetingWorkingFileCleanup.filesToDelete` (`Sources/MustardKit/Logic/MeetingWorkingFileCleanup.swift:35-50`)
only ever appends `source.partialTrack` (never `.finalTrack`) or the literal
`.recoveryManifest` case. It is *structurally* impossible for this function to
return `.you`, `.meeting`, or `.playback` — not just tested, unreachable by
construction. Confirmed with `test_playbackNeverInTheDeleteList_acrossEveryScenario`
(`MeetingWorkingFileCleanupTests.swift:86-100`), which also asserts `.you`/`.meeting`
never appear, across 4 scenarios.

Per-channel rule: a channel's partial is appended only when
`finalsThatExist.contains(source)` — confirmed by
`test_oneFinalMissing_deletesOnlyTheOtherPartial_keepsManifest` (line 25-40):
mic final missing → only the other partial returned, mic partial and manifest
both survive. This is exactly the BAK-332 interaction in item 3: a
started-but-never-finalized channel keeps its only surviving audio, and the
manifest (which still tracks that channel's byte/sample offsets) is also kept,
because the manifest rule (`startedSources.isSubset(of: finalsThatExist)`) is
strictly all-or-nothing across started channels, not per-channel. Verified the
real end-to-end BAK-332 shape too
(`MeetingCaptureCoordinatorTests.swift:220-270`,
`test_micWriterNeverWritesAFile_...`): `record.youAudioPath` is nil after stop,
`record.meetingAudioPath` is stamped — the coordinator's `finalsThatExist` set
would be `{.meeting}` only, mapping 1:1 onto the pure unit test above (that
test doesn't assert on-disk file state, but the pure-unit coverage plus the
coordinator's live `FileManager.fileExists` checks — not cached flags — close
that gap).

**Standards/Spec: PASS.**

## Coordinator control-flow diff (item 2)

Actual diff (`git diff origin/main..HEAD -- .../MeetingCaptureCoordinator.swift`)
confirms the new branch is inserted *before* the pre-existing guard:

```swift
if record.status == .ready, record.audioFinalized {
    cleanUpWorkingFiles(for: record)
    continue
}
guard record.status != .ready else { continue }   // unchanged
record.status = .partial                          // unchanged
```

Enumerated every combination:
- `status == .ready && audioFinalized == true` → **new**: cleanup + continue,
  no promotion (unchanged: never promoted before either).
- `status == .ready && audioFinalized == false` → falls through to the old
  guard, which still fires (`status == .ready` → continue). **Byte-identical**
  to pre-diff behavior: no cleanup, no promotion, in either version.
- `status != .ready` (any status, any `audioFinalized`) → old guard doesn't
  fire, falls through to the unchanged promote-to-`.partial` block. No path
  through the new code touches this branch at all.

Whether `status == .ready && audioFinalized == false` is even reachable: I
traced every place `MeetingRecord.status` is set to `.ready` in
`Sources/MustardKit/` (only one: `apply(.digestReady)` inside `stop()`,
`MeetingCaptureCoordinator.swift:264`) and confirmed `record.audioFinalized =
true` is set unconditionally earlier in the same synchronous call
(`stop()` line 240) with no early return in between under current code. So
today this combination can't occur from a clean run — but see the crash-window
finding below, which is precisely how it *could* arise on disk in a way that
matters.

**Standards/Spec: PASS** — no pre-existing case changes behavior; the new
branch only intercepts the one combination the task describes.

## Crash-window reasoning (item 4 — flagged NON-BLOCKING per the task's own framing, but something can break)

Traced the exact window between `cleanUpWorkingFiles(for: record)`
(`MeetingCaptureCoordinator.swift:241`, right after `stampAudioPaths`/
`audioFinalized = true` at 239-240) and the next `context.save()`. Every
`apply(_:)` call unconditionally saves when `activeMeeting` is set
(`MeetingCaptureCoordinator.swift:342-349`); the closest prior save is
`apply(.transcriptFinalized)` at line 233 (persists `status = .finalizing`,
**before** cleanup runs), and the closest next save is either the digest
branch's `try? context.save()` (line 256, if a digest generator is
configured) or `apply(.digestReady)` (line 264, unconditionally). Between
line 241 and whichever comes first, the only code is `applySourceParity`
(synchronous) and a plain field assignment — no `await`, no I/O.

If the process dies in that window: the crash-recovery scratch files
(partials + `recovery.json`) have already been deleted from disk by
`cleanUpWorkingFiles`, but `record.audioFinalized = true` was never
persisted — the last saved status is `.finalizing`. On next launch,
`recoverOnLaunch()` drives entirely off *discovering a `recovery.json` on
disk* (`MeetingCaptureCoordinator.swift:308-313`): with the manifest gone,
this meeting's directory is never visited at all, so the stuck
`.finalizing` record is never touched, never promoted to `.partial`, and
has no other recovery path in the codebase (`MeetingReviewView.swift:134`
just renders "Finishing…" indefinitely; grepped for any other stuck-state
handling and found none).

Compared against pre-diff behavior in the *same* crash window: before this
change, nothing deleted the manifest, so `recoverOnLaunch()` would still find
it, see `status != .ready` (persisted value is `.finalizing`), and correctly
promote to `.partial` — self-healing. This diff removes that self-healing
specifically in this narrow window, for a case the acceptance criteria don't
literally cover (AC says "crash *before* finalize," this is crash-after-
finalize-but-before-persistence). Likelihood is very low — the window is a
few instructions of synchronous, non-suspending Swift with no I/O — but it is
a real, if narrow, regression in the belt-and-suspenders crash safety this
file is built around, and it's worth a follow-up: e.g., save the record
(or at least `audioFinalized`) before calling `cleanUpWorkingFiles`, so the
persisted state and the deleted evidence can never disagree about which one
happened.

**Risk: NON-BLOCKING** — matches the task's own pre-labeling of item 4, but
reporting the concrete failure mode since it is real, not hypothetical: a
crash in this exact window permanently strands a meeting at "Finishing…"
with no recovery affordance, where it previously would have recovered to
`.partial`.

## Retention overlap

`git diff` confirms zero changes to `MeetingRetention.swift` or
`MeetingAudioStore.swift`. Read `MeetingRetention.deleteAudio` — it calls
`store.deleteAudio(forMeetingUID:)`, which removes the whole
`Recordings/<uid>/` directory in one `removeItem` (confirmed at
`MeetingAudioStore.swift:112-116` region). No double-handling: retention's
full-directory delete is correct whether or not this task's narrower cleanup
already ran.

**Spec: PASS.**

## Best-effort / validated-path requirement

`cleanUpWorkingFiles` (`MeetingCaptureCoordinator.swift:482-513`) builds every
URL through `store.fileURL(for:meetingUID:)` — no raw path concatenation
anywhere in the diff. The delete loop skips files that are already absent
(`FileManager.fileExists` check before `removeItem`) and wraps the actual
removal in `do`/`catch` that only logs (`voiceLog.error`, uid + filename, no
transcript content) — no field on `record` is touched on failure. Confirmed
no dedicated failure-injection test exists (`task.md`'s "Deviations" section
owns this explicitly, with a stated reason: `FileManager.default` is called
directly throughout this file already, matching every other file-existence
check, so there's no cheap seam to inject a failure).

**Test Review: PASS** with one acknowledged, justified gap (best-effort
failure path has no dedicated test, but is trivially safe by inspection — a
`do`/`catch` around one `removeItem` call with no side effects in the `catch`).

## Verification — commands run directly (not trusted from verification.md)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingWorkingFileCleanupTests
→ Executed 7 tests, with 0 failures (0 unexpected). Exit 0.

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
→ Executed 21 tests, with 0 failures (0 unexpected). Exit 0.

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
→ Executed 1559 tests, with 1 test skipped and 0 failures (0 unexpected). Exit 0.
  (the 1 skip is the pre-existing, unrelated SnapshotRenderTests.test_renderScreens,
   gated on MUSTARD_SNAPSHOT=1 — confirmed unrelated to this diff)

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
→ Build complete! Exit 0.
```

Matches the claimed 1559 pass / 1 skip / 0 fail exactly.

## Axis summary

| Axis | Verdict |
|---|---|
| Standards | PASS — pure decision in `Logic/`, coordinator only executes through validated `MeetingAudioStore` paths, no raw path building, style matches surrounding file, no unrelated refactors |
| Spec | PASS — all four acceptance criteria implemented and verified directly (see sections above); no unrequested behavior; retention correctly left alone |
| Risk | Medium (deletes files, but only regenerable crash-recovery scratch copies, never finals/playback) — matches `risk-report.md`'s self-classification. One NON-BLOCKING crash-window finding (above); no BLOCKING risk findings. No irreversible outward action; not pushed, no PR opened |
| Tests | PASS — red-first proof re-verified in `verification.md` is consistent with the diff; full suite and both filtered suites re-run independently with matching results; one acknowledged, justified test-coverage gap (best-effort failure path) |

## Findings

1. **[NON-BLOCKING]** `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift:241` —
   `cleanUpWorkingFiles(for: record)` runs before `record.audioFinalized = true`
   is durably persisted (next save is line 256 or 264). A crash in that narrow,
   synchronous, no-I/O window deletes the crash-recovery manifest before the
   persisted record reflects finalization, permanently stranding the meeting
   at `.finalizing` ("Finishing…") with no recovery path — a real, if very
   low-probability, regression in the self-healing `recoverOnLaunch()`
   previously provided for this exact timing. Suggested follow-up (not
   required to land this PR): persist `audioFinalized = true` before invoking
   `cleanUpWorkingFiles`.

No blocking findings.

VERDICT: mergeable

Commands run: `swift test --filter MeetingWorkingFileCleanupTests`,
`swift test --filter MeetingCaptureCoordinatorTests`, `swift test` (full
suite), `swift build` — all under
`DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer`, all exit 0.
