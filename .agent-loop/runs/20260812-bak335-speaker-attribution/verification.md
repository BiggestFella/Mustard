# BAK-335 verification

## Baseline (re-confirmed on `origin/main`, before any change)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at ...
	 Executed 1577 tests, with 1 test skipped and 0 failures (0 unexpected) in ...
Test Suite 'All tests' passed ...
```
Matches the task's stated baseline (1577 pass / 1 skip) exactly. Exit code `0`.

## Red-first proof, unit by unit

### `MeetingSpeakerAttribution` (pure detection + attribution)

Wrote `Tests/MustardTests/MeetingSpeakerAttributionTests.swift` (29 tests)
against a real implementation, then TEMPORARILY replaced
`Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift` with a stub
(`detectHandoffs` → `[]`, `attribute` → all-nil) to prove genuine red before
restoring the real implementation:

```
swift test --filter MeetingSpeakerAttributionTests
```
```
Test Suite 'MeetingSpeakerAttributionTests' failed ...
	 Executed 29 tests, with 23 failures (0 unexpected) in 0.373 seconds
```
Restored the real implementation:
```
Test Suite 'MeetingSpeakerAttributionTests' passed ...
	 Executed 29 tests, with 0 failures (0 unexpected) in 0.007 seconds
```

### `MeetingSpeakerCandidateSource` (candidate assembly)

Wrote `Tests/MustardTests/MeetingSpeakerCandidateSourceTests.swift` (5
tests) before the type existed:
```
swift test --filter MeetingSpeakerCandidateSourceTests
```
```
error: cannot find 'MeetingSpeakerCandidateSource' in scope
```
(compile failure — genuine red). After implementing:
```
Test Suite 'MeetingSpeakerCandidateSourceTests' passed ...
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.042 seconds
```

### `MeetingUtteranceMerge` (speaker boundary)

Extended `Tests/MustardTests/MeetingUtteranceMergeTests.swift` with 6 new
tests (speaker breaks a run, nil↔named breaks a run, same speaker doesn't
break, `speaker`/`asSegment.speaker` exposed) before adding the `speaker`
computed property:
```
error: value of type 'MeetingUtterance' has no member 'speaker'
```
(compile failure — genuine red). After implementing:
```
Test Suite 'MeetingUtteranceMergeTests' passed ...
	 Executed 17 tests, with 0 failures (0 unexpected) in 0.009 seconds
```

### `MeetingDigestService` (speaker prefix)

Extended `Tests/MustardTests/MeetingDigestServiceTests.swift` with 3 new
tests before changing the service:
```
swift test --filter MeetingDigestServiceTests
```
```
Test Suite 'MeetingDigestServiceTests' failed ...
	 Executed 15 tests, with 1 failure (0 unexpected) in 0.360 seconds
```
(the attributed-prefix test failed as expected; the unattributed/nil-speaker
test already passed, since unprefixed was already the existing behavior —
kept as an explicit regression guard). After implementing:
```
Test Suite 'MeetingDigestServiceTests' passed ...
	 Executed 15 tests, with 0 failures (0 unexpected) in 0.012 seconds
```

### `MeetingCaptureCoordinator` (finalize wiring)

Extended `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` with 2
new tests before wiring attribution into `stop()`:
```
swift test --filter MeetingCaptureCoordinatorTests
```
```
Test Suite 'MeetingCaptureCoordinatorTests' failed ...
	 Executed 23 tests, with 2 failures (0 unexpected) in 0.823 seconds
```
After implementing (`attributedSpeakers(for:context:)` + threading through
`transcriptSegment(from:)`):
```
Test Suite 'MeetingCaptureCoordinatorTests' passed ...
	 Executed 23 tests, with 0 failures (0 unexpected) in 0.472 seconds
```
(One test-construction bug was found and fixed along the way, not an
implementation bug: the retry test initially fetched the wrong
`MeetingRecord` via `.first` when two records existed in the context — the
past meeting used for candidate seeding, and the new one — fixed by
filtering on title.)

### `MeetingTranscriptView` (review UI)

Views are build-and-eye verified per this repo's testing rules, not unit
tested. `swift build` after the change:
```
Building for debugging...
Build complete! (6.98 sec)
```

## Final full-suite run

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 10:21:36.618.
	 Executed 1622 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.546 (8.694) seconds
Test Suite 'All tests' passed at 2026-08-12 10:21:36.618.
	 Executed 1622 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.546 (8.702) seconds
```
Exit code `0`. 1622 − 1577 = 45 new tests, all passing; the pre-existing
skipped test is unchanged and unrelated to this work.

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```
```
Building for debugging...
Build complete! (0.48 sec)
```
Exit code `0`.

## Pre-existing failures

None. Baseline was clean (1577/1577 non-skipped passing, 1 skip) and stays
clean.
