# BAK-333: finalized meetings keep their crash-recovery working files forever

## Problem (given, verified on disk)

A `ready` 23-minute meeting held `meeting.m4a` (39 MB) + `meeting.partial.caf`
(284 MB) + `playback.m4a` + `recovery.json` — ~285 MB of dead weight per
meeting, ~7x the audio it actually kept. `recoverOnLaunch` already guards on
`record.status != .ready`, so correctness never depended on these files
sticking around once a meeting finalized — this is purely a storage leak.

## Investigation

- `Sources/MustardKit/Meeting/MeetingAudioStore.swift` — validated
  `Recordings/<uid>/` path arithmetic (`fileURL(for:meetingUID:)`,
  `MeetingAudioFile` enum). All deletion in this task goes through this.
  `deleteAudio(forMeetingUID:)` (lines 112-116) already removes the WHOLE
  per-meeting directory via `fileManager.removeItem(at: url)` — see
  "Retention finding" below.
- `Sources/MustardKit/Meeting/MeetingAudioWriter.swift` — `finalizeSources()`
  (lines 107-117) converts each recorded source's `.partial.caf` to its
  final `.m4a` but never deletes the partial ("Partials are preserved
  through every failure AND after success — deletion is retention's job
  (Task 10)", the file's own doc comment, line 20). `mixPlayback()`
  (lines 121-142) produces `playback.m4a` from whichever finals exist.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — `stop()`
  (lines 182-266): `stampAudioPaths(on:)` (line 239, now 446-456) stamps a
  channel's relative path only if `FileManager.fileExists` at that URL right
  now — this is the "final actually exists" signal the brief asks for, and
  it's the same signal `applySourceParity` (BAK-332) already reads via
  `record.youAudioPath`/`meetingAudioPath`. `record.audioFinalized = true`
  follows at line 240. `recoverOnLaunch()` (lines 303-327, now extended)
  reads every discoverable `recovery.json`, and for a record whose
  `status == .ready` it previously just `continue`d past it — i.e. it
  already *noticed* the leftover manifest for finished meetings and did
  nothing about it.

### Retention finding

`MeetingRetention.deleteAudio` (`Sources/MustardKit/Logic/MeetingRetention.swift`,
lines 34-46) calls `store.deleteAudio(forMeetingUID:)`, which removes the
entire `Recordings/<uid>/` directory — partials, manifest, finals, playback,
everything — in one `removeItem`. **Retention already leaves no partials
behind; no change was made there.** This task's leak is specifically the
window between a meeting reaching `ready` and its eventual 30-day retention
sweep (or indefinitely, for a pinned meeting) — that window is where the
~285 MB/meeting was accumulating.

## Design decisions

1. **Hook point: the coordinator, right after `stampAudioPaths`/
   `audioFinalized = true`.** Considered making `MeetingAudioWriter` the
   owner instead (it already knows which sources it finalized), but rejected
   it: the writer's own doc comment explicitly defers this to "retention's
   job (Task 10)" and the writer has no visibility into `record.captureSources`
   (which sources were actually *started*, as opposed to which happened to
   open a track) — that distinction is exactly what BAK-332's parity logic
   needed the coordinator's `MeetingRecord` for, and this task needs the same
   distinction (a started-but-never-finalized source must keep its partial).
   The coordinator is the only place with both facts. One `cleanUpWorkingFiles(for:)`
   call was added right after `record.audioFinalized = true` — before
   `applySourceParity`, though ordering between the two doesn't matter since
   parity reads persisted record fields, not disk state.
2. **The decision is pure, `filesToDelete` is not.** New file
   `Sources/MustardKit/Logic/MeetingWorkingFileCleanup.swift`:
   `filesToDelete(startedSources:finalsThatExist:hasManifest:) -> [MeetingAudioFile]`.
   Three inputs, as specified: which channels the meeting started
   (`record.captureSources` mapped through `MeetingAudioSource.trackChannel`),
   which channels' finals are verified on disk right now, and whether
   `recovery.json` is currently present. The coordinator's
   `cleanUpWorkingFiles(for:)` gathers those three facts and executes the
   returned list through `store.fileURL(for:meetingUID:)` +
   `FileManager.removeItem`, skipping (not erroring on) any file that's
   already gone.
3. **Manifest-deletion rule.** `recovery.json` deletes only once **every**
   started channel's final exists (`startedSources.isSubset(of: finalsThatExist)`).
   Reasoning: the manifest's whole purpose is recording safe byte/sample
   offsets for a channel that might still need to resume — a channel whose
   final is missing (BAK-332's exact failure mode: the writer silently never
   finalized it) is the one case where the manifest's tracked offsets for
   *that* channel could still matter to a future recovery attempt. Deleting
   it early would discard the one thing that channel has left. An empty
   `startedSources` (nothing left to track — the launch-sweep edge case)
   makes the subset check vacuously true, so a manifest with nothing left to
   protect is itself the only leftover and gets swept.
4. **Per-channel partial deletion is independent of the manifest rule.** A
   channel's `.partial.caf` deletes as soon as *that* channel's final exists
   — it does not wait for every channel to finalize. This is what keeps a
   mixed BAK-332 case correct: if `you` finalized but `meeting` didn't,
   `you.partial.caf` is reclaimed immediately while `meeting.partial.caf`
   (the only surviving meeting audio) and `recovery.json` (still tracking
   `meeting`'s offsets) both stay.
5. **Deletion is strictly best-effort.** A failure logs via `voiceLog.error`
   naming the uid and file, and never touches `record.status`,
   `audioFinalized`, or any other field — cleanup is a side effect of a
   successful finalize, never a gate on it.
6. **One-off launch sweep.** `recoverOnLaunch()` already iterates every
   directory with a discoverable `recovery.json`. Extended it: when the
   matched record is `status == .ready && audioFinalized`, run
   `cleanUpWorkingFiles(for:)` and `continue` — never falling through to the
   partial-promotion branch below it, which would wrongly demote an already
   finished meeting. This clears the backlog already sitting on disk from
   before this cleanup existed, using the exact same pure decision and
   execution path as the live finalize hook.

## Files touched

- `Sources/MustardKit/Logic/MeetingWorkingFileCleanup.swift` — new, pure.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` —
  `cleanUpWorkingFiles(for:)` helper; called from `stop()` and from
  `recoverOnLaunch()`'s new one-off sweep branch.
- `Tests/MustardTests/MeetingWorkingFileCleanupTests.swift` — new.
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — extended: clean
  finalize deletes partials+manifest, an interrupted finalize leaves them
  intact, and the launch sweep cleans an already-ready record's leftovers.
- `.agent-loop/runs/20260812-bak333-finalize-cleanup/` — this run's artifacts.

## Acceptance criteria checklist

- [x] `MeetingWorkingFileCleanup.filesToDelete` pure unit, written and
      confirmed red (compile failure — the type didn't exist) before
      implementation: both finals exist → both partials + manifest; one
      final missing → only the other partial, manifest kept; no finals →
      nothing; a missing manifest never gets invented; `playback.m4a` and
      the finalized `.m4a`s are never in any returned list, across every
      scenario tested; the vacuous "no started sources left to track, stale
      manifest only" edge case → manifest alone. 7 tests, all green.
- [x] Coordinator: a clean stop deletes both partials + the manifest and
      leaves the finals + playback untouched.
- [x] Coordinator: an interrupted stop (the real fallback-file-transcription
      failure path, reached AFTER the writer already finalized both
      channels to disk but BEFORE `audioFinalized = true`) leaves every
      partial and the manifest exactly where they were — cleanup only ever
      runs after a fully successful finalize.
- [x] Coordinator: `recoverOnLaunch()` sweeps an already-`ready` record's
      leftover partials + manifest without touching its status, and never
      touches the finalized `.m4a`s.
- [x] Retention finding: `MeetingRetention.deleteAudio` already removes the
      whole `Recordings/<uid>/` directory — confirmed, no change made there.
- [x] `swift test` full suite green (1559 pass / 1 skip / 0 failures, exit
      0 — 1549 baseline + 10 new), `swift build` exit 0.
- [x] No push, no PR — stopped after local commits.

## Deviations from the brief

- A dedicated "deletion failure doesn't change record status" coordinator
  test was scoped out: there is no cheap, pre-existing seam to inject a
  `FileManager` failure into `MeetingCaptureCoordinator` (it calls
  `FileManager.default` directly, matching every other file-existence check
  already in this file — e.g. `stampAudioPaths`, the `hasMeetingTrack` check
  in `stop()`). The brief explicitly allows skipping this ("if injectable
  cheaply"). The best-effort `do`/`catch` + `voiceLog.error` in
  `cleanUpWorkingFiles` is straightforward enough to be low-risk without a
  dedicated test, and every other test already exercises the success path
  through the same code.
