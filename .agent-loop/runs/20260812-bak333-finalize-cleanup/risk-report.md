# Risk report — BAK-333

## Labels

- Bug (storage leak: crash-recovery scratch files were never reclaimed after
  a meeting finished, ~7x the audio actually kept)

## Touched paths

- `Sources/MustardKit/Logic/MeetingWorkingFileCleanup.swift` — new file, under `Sources/`
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — under `Sources/`
- `Tests/MustardTests/MeetingWorkingFileCleanupTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — under `Tests/`
- `.agent-loop/runs/20260812-bak333-finalize-cleanup/` — run artifacts

Per `.agent-loop/risk.yml` path_risk: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern — `ClaudeRunner`, `TrustPolicy`,
`RecommendationAction`, `auth`, `oauth`, `.env`, `secret`, and
`.github/workflows/` are all untouched.

## Risk class: medium

- **Deletes user files — the one fact worth flagging.** This change makes
  `MeetingCaptureCoordinator` delete files on disk for the first time outside
  of the pre-existing, already-shipped `MeetingRetention`/`MeetingAudioStore`
  paths. Every deletion:
  - goes through `MeetingAudioStore.fileURL(for:meetingUID:)` — the same
    validated, traversal-rejecting path arithmetic `MeetingRetention` already
    relies on; no raw path building anywhere in this change.
  - only ever targets `MeetingAudioFile.youPartial`, `.meetingPartial`, and
    `.recoveryManifest` — the three crash-recovery *scratch* files. The
    pure decision unit (`MeetingWorkingFileCleanup.filesToDelete`) has no
    branch that can return `.you`, `.meeting`, or `.playback`, and a test
    (`test_playbackNeverInTheDeleteList_acrossEveryScenario`) asserts this
    across every input combination exercised.
  - is gated on the target channel's finalized `.m4a` being verified present
    on disk right now (`FileManager.fileExists`, not a cached/stale flag) —
    a channel that never finalized keeps its only surviving audio.
  - is best-effort: a failure logs (`voiceLog.error`, uid + filename only,
    never transcript content) and never touches `record.status`,
    `audioFinalized`, or any other field.
- **Additive, narrow surface.** `MeetingWorkingFileCleanup` is a new, pure,
  side-effect-free type — it cannot regress anything by existing.
  `MeetingCaptureCoordinator` gained one new private method
  (`cleanUpWorkingFiles(for:)`) called from two places: once in the existing
  `stop()` pipeline (after the point where `audioFinalized` already flips to
  `true` — no new *decision* branch in that pipeline, only a cleanup side
  effect after success) and once in `recoverOnLaunch()`'s existing loop
  (a new `continue` branch that runs before the pre-existing partial-promotion
  logic; it cannot fire for a record that isn't already `.ready` +
  `audioFinalized`, so it cannot touch a meeting mid-recording or one still
  correctly showing as partial/interrupted).
- **No schema change.** No new `@Model` field. `MeetingAudioFile` (existing
  enum) and `MeetingSegmentSource` (existing enum) are reused as-is.
- **Crash safety verified, not assumed.** A dedicated coordinator test
  (`test_stopPipeline_interruptedAfterAudioFinalizes_leavesPartialsAndManifestIntact`)
  drives a real interrupt path — the after-Stop fallback file-transcription
  failure — that reaches `interrupt()` AFTER the writer already wrote both
  finals to disk but BEFORE `stampAudioPaths`/`audioFinalized = true`/cleanup
  run, and asserts every partial and the manifest survive untouched.
- **Retention overlap checked, not assumed.** Verified
  `MeetingRetention.deleteAudio` already removes the whole
  `Recordings/<uid>/` directory in one `removeItem` — this task's cleanup and
  retention's eventual full-directory delete never race or double-handle the
  same file in a way that matters (retention's `removeItem` on a directory
  that already lost its partials/manifest is still correct — it's removing a
  directory that now only holds finals + playback, same as any other expired
  meeting).

Nothing here rises to `high`: no auth/secret/deployment surface, no money, no
irreversible effect (deleted files are exactly the byte-identical scratch
copies of data that survives elsewhere as the finalized `.m4a`/transcript),
no change to autonomous-run gating.

## Outward actions

None. No git tags, releases, remote-ref deletions, secret rotation, or force
pushes. No network calls; entirely local (SwiftData + `FileManager` logic).
Branch not pushed, no PR opened, per the task's explicit instruction.

## Notes

- The manifest-deletion rule (deletes only once EVERY started channel's
  final exists, not per-channel) is the one place this task asked for
  judgment — documented in `task.md` under "Design decisions" #3, flagged
  here again for reviewer attention: a partial per-channel manifest-deletion
  rule was considered and rejected because the manifest is a single JSON
  file per meeting (not per-channel), so "delete it" is all-or-nothing
  regardless; the question was only *when*, and the answer chosen is "once
  it has nothing left to protect."
- The "deletion failure doesn't change record status" test was scoped out
  as not cheaply injectable — see `task.md`'s Deviations section. This is a
  test-coverage gap, not a behavioral gap: the `do`/`catch` in
  `cleanUpWorkingFiles` already ensures a thrown `FileManager` error cannot
  propagate into `stop()`/`recoverOnLaunch()`'s control flow.
