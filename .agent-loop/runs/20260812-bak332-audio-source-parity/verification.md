# BAK-332 verification

## Baseline (before any change)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
`Test Suite 'All tests' passed ... Executed 1539 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.327 (7.438) seconds` — matches the stated baseline exactly.

## Red-first proof

1. `Tests/MustardTests/MeetingSourceParityTests.swift` written against a
   `MeetingSourceParity` type that did not exist yet. `swift test --filter
   MeetingSourceParityTests` failed to COMPILE (`reference to member
   'meeting' cannot be resolved without a contextual type`, etc. — the
   contextual type comes from the missing `MeetingSourceParity.evaluate`
   signature). Confirmed red before `Sources/MustardKit/Logic/MeetingSourceParity.swift`
   was written.
2. `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` gained
   `test_micWriterNeverWritesAFile_whileTranscriptionSucceeds_flagsParity_keepsRecordingAndTranscript`.
   With the coordinator fix already applied, this test passed — so to prove
   it was a real regression test (not vacuously true), the coordinator
   change was TEMPORARILY reverted (`git checkout --
   Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift`, fix backed up
   first) and the test re-run:

   ```
   Test Case '...test_micWriterNeverWritesAFile_whileTranscriptionSucceeds_flagsParity_keepsRecordingAndTranscript]' failed
   XCTAssertEqual failed: ("nil") is not equal to
   ("Optional("Microphone audio was not saved — the transcript is unaffected.")")
   - the mismatch is surfaced, naming the exact lost channel, instead of being silently clean
   ```

   The sibling clean-recording test
   (`test_bothSourcesFinalize_matchingTheirTranscripts_leavesErrorMessageNil`)
   still passed on the reverted coordinator, confirming the failure is
   specific to the missing-audio scenario, not a fixture bug. The coordinator
   fix was then restored from the backup and both tests pass again.

## After implementation — full suite

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```

```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 08:58:22.776.
	 Executed 1549 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.395 (7.500) seconds
Test Suite 'All tests' passed at 2026-08-12 08:58:22.777.
	 Executed 1549 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.395 (7.507) seconds
```

Exit code: `0`. 1549 = 1539 baseline + 10 new (8 `MeetingSourceParityTests` +
2 `MeetingCaptureCoordinatorTests`). 1 skip unchanged (pre-existing, unrelated
to this change).

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```

```
Building for debugging...
Build complete! (1.74 sec)
```

Exit code: `0`.

## New test inventory

- `Tests/MustardTests/MeetingSourceParityTests.swift` (8 tests): all-good,
  missing-you-audio, missing-meeting-audio, source-never-started (never
  flagged), started-then-lost (flagged), empty-transcript-clean-audio
  (clean), empty-transcript-and-empty-audio (not flagged — no evidence
  either way), both-sources-missing (deterministic multi-name message).
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` (+2 tests):
  the incident-shaped regression (mic writer throws on every append via a
  mismatched sample rate while the transcription stub still returns real
  segments — `status` stays `.ready`, `audioFinalized` stays `true`,
  `youAudioPath` stays `nil`, `meetingAudioPath` finalizes normally,
  `errorMessage` names the microphone, transcript segment persists intact)
  and a clean two-source control (`errorMessage` stays `nil`).
