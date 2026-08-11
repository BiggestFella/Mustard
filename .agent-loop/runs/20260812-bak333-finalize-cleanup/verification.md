# BAK-333 verification

## Baseline (before any change — re-confirmed by stashing this task's edits
and re-running against origin/main, not just trusted from the brief)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 09:19:28.496.
	 Executed 1549 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.500 (7.603) seconds
```
Matches the stated baseline (1549 pass / 1 skip) exactly.

## Red-first proof

1. `Tests/MustardTests/MeetingWorkingFileCleanupTests.swift` written against
   a `MeetingWorkingFileCleanup` type that did not exist yet.
   `swift test --filter MeetingWorkingFileCleanupTests` failed to **compile**:
   `error: cannot find 'MeetingWorkingFileCleanup' in scope` and
   `error: reference to member 'recoveryManifest' cannot be resolved without
   a contextual type` (the contextual type comes from the missing
   `filesToDelete` signature). Confirmed red before
   `Sources/MustardKit/Logic/MeetingWorkingFileCleanup.swift` was written.
   After implementation: 7/7 pass.

2. `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` gained three
   tests, added BEFORE `cleanUpWorkingFiles`/the `recoverOnLaunch` sweep
   were wired into `MeetingCaptureCoordinator.swift`. Ran the full
   `MeetingCaptureCoordinatorTests` suite in that state:

   ```
   Test Case '...test_stopPipeline_cleanFinalize_deletesPartialsAndManifest_keepsFinalsAndPlayback]' failed
   .../MeetingCaptureCoordinatorTests.swift:321: XCTAssertFalse failed - the you partial is dead weight once you.m4a is verified on disk
   .../MeetingCaptureCoordinatorTests.swift:325: XCTAssertFalse failed - the meeting partial is dead weight once meeting.m4a is verified on disk
   .../MeetingCaptureCoordinatorTests.swift:329: XCTAssertFalse failed - every started source finalized — the manifest has nothing left to protect

   Test Case '...test_recoverOnLaunch_cleansUpLeftoverWorkingFiles_forAnAlreadyReadyRecord]' failed
   .../MeetingCaptureCoordinatorTests.swift:459: XCTAssertFalse failed
   .../MeetingCaptureCoordinatorTests.swift:461: XCTAssertFalse failed
   .../MeetingCaptureCoordinatorTests.swift:463: XCTAssertFalse failed

   Test Suite 'MeetingCaptureCoordinatorTests' failed ... Executed 21 tests, with 6 failures (0 unexpected)
   ```

   The third new test
   (`test_stopPipeline_interruptedAfterAudioFinalizes_leavesPartialsAndManifestIntact`)
   already PASSED in this pre-wiring state — correctly, since it asserts
   nothing was deleted and at that point nothing could be (no cleanup code
   existed anywhere yet); it is a true regression guard against a *future*
   change that starts running cleanup on the interrupt path, not a red-first
   test for this change. The two positive tests failing exactly as expected,
   with the exact assertions this task's design says should pass, confirms
   both are real (not vacuously true) before implementation.

   After wiring `cleanUpWorkingFiles(for:)` into `stop()` and
   `recoverOnLaunch()`: all 21 tests (18 pre-existing + 3 new) pass.

## After implementation — full suite

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 09:19:53.772.
	 Executed 1559 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.433 (7.537) seconds
Test Suite 'All tests' passed at 2026-08-12 09:19:53.772.
	 Executed 1559 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.433 (7.543) seconds
```
Exit code: `0`. 1559 = 1549 baseline + 10 new (7 `MeetingWorkingFileCleanupTests`
+ 3 `MeetingCaptureCoordinatorTests`). 1 skip unchanged (pre-existing,
unrelated to this change).

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```
```
Building for debugging...
Build complete! (0.47 sec)
```
Exit code: `0`.

## New test inventory

- `Tests/MustardTests/MeetingWorkingFileCleanupTests.swift` (7 tests):
  both-finals-exist (both partials + manifest), one-final-missing (only the
  other partial, manifest kept), no-finals (nothing), single-started-source
  (its partial + manifest), no-manifest-on-disk (never fabricated even when
  every final exists), manifest-only-leftover / no started sources left to
  track (manifest alone, the vacuous-subset edge case), playback-never-in-list
  (asserted across four scenarios, alongside "a finalized `.m4a` is never
  deleted").
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` (+3 tests): a
  clean two-source stop deletes both partials + the manifest and leaves both
  finals + `playback.m4a` untouched; an interrupted stop (via a real
  fallback-file-transcription failure, reached after both channels already
  finalized to disk but before `audioFinalized = true`) leaves every partial
  and the manifest exactly where they were; `recoverOnLaunch()` sweeps an
  already-`ready`/`audioFinalized` record's leftover partials + manifest
  without touching its status or its finalized audio.
