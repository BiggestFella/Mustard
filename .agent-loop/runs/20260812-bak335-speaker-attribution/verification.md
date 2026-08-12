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

---

## Review fix round — red-first evidence per finding

### FINDING 1 + FINDING 2 (`MeetingSpeakerAttributionTests`)

Added 11 tests (reviewer's exact repros + the requested extra cases +
non-regression guards for the unaffected phrase families) BEFORE touching
`MeetingSpeakerAttribution.swift`:

```
swift test --filter MeetingSpeakerAttributionTests
```
```
	 Executed 40 tests, with 5 failures (0 unexpected) in 0.656 seconds
```
Failures (verbatim):
```
test_attribute_ambiguousCandidateMatch_staysUnattributed_reviewerRepro : XCTAssertEqual failed: ("[nil, Optional("Alina")]") is not equal to ("[nil, nil]")
test_attribute_bareOverTo_midSentence_isNotAHandoff_reviewerRepro : XCTAssertEqual failed: ("[nil, Optional("Sam")]") is not equal to ("[nil, nil]")
test_detectHandoffs_bareOverTo_midSentence_producesNoHandoff_reviewerRepro : XCTAssertTrue failed
test_detectHandoffs_possessiveName_isNeverAHandoff : XCTAssertTrue failed
test_detectHandoffs_possessiveName_isNeverAHandoff_evenWithoutTrailingPunctuation : XCTAssertTrue failed
```
(One test-authoring bug found in the same pass, not a production bug:
`test_detectHandoffs_handOverTo_isNotRestrictedByClauseEnd`'s own fixture
text let the pre-existing 2-token name capture greedily swallow "and" —
fixed by adding a comma in the fixture, unrelated to the review findings.)

Implemented both fixes (possessive rejection; capturing-grouped phrase
alternatives + clause-end check restricted to the bare "over to" group;
ambiguous-match → nil). Re-ran:
```
	 Executed 40 tests, with 1 failure (0 unexpected) in 0.382 seconds
```
Remaining failure was a genuine, EXPECTED regression in a pre-existing
test whose fixture relied on the exact behavior just tightened
(`test_detectHandoffs_secondTokenStopsAtPunctuation` used bare "over to"
with trailing multi-sentence content). Rewrote that fixture to use "back
to you," instead (a family with no clause-end restriction), preserving the
test's real intent (second name token stops at punctuation). Final run:
```
Test Suite 'MeetingSpeakerAttributionTests' passed at 2026-08-12 10:37:11.075.
	 Executed 40 tests, with 0 failures (0 unexpected) in 0.008 (0.010) seconds
```

Full-suite check after this fix (catches any interaction elsewhere):
```
Executed 1633 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.478 (8.608) seconds
```

### FINDING 3 (`MeetingCaptureCoordinatorTests`)

Added `test_finalize_mergesWordLevelFragmentsBeforeAttribution_
stampsEveryConstituent` (genuinely word-level fragments: "pass it" / "back
to" / "Alex." / "I shipped" / "the release") BEFORE touching
`MeetingCaptureCoordinator.swift`:
```
swift test --filter test_finalize_mergesWordLevelFragmentsBeforeAttribution_stampsEveryConstituent
```
```
error: ... XCTAssertEqual failed: ("nil") is not equal to ("Optional("Alex")") - every constituent of the attributed utterance is stamped
error: ... XCTAssertEqual failed: ("nil") is not equal to ("Optional("Alex")") - not just the first constituent
	 Executed 1 test, with 2 failures (0 unexpected) in 0.574 seconds
```
Implemented the utterance-merge-first fix in `attributedSpeakers(for:
context:)`. Also widened the two PRE-EXISTING speaker-attribution
coordinator tests' segment gaps to >= 1.5s (a no-op under the old
per-segment code, confirmed still green before touching the
implementation) so they stay one-utterance-per-line under the new
merge-first path rather than accidentally merging into one blob and
tripping FINDING 1(b)'s clause-end check. Re-ran:
```
Test Suite 'MeetingCaptureCoordinatorTests' passed at 2026-08-12 10:39:48.369.
	 Executed 24 tests, with 0 failures (0 unexpected) in 0.643 (0.646) seconds
```

## Final full-suite run (after all three fixes)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 10:40:05.112.
	 Executed 1634 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.342 (8.473) seconds
Test Suite 'All tests' passed at 2026-08-12 10:40:05.112.
	 Executed 1634 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.342 (8.481) seconds
```
Exit code `0`. 1634 − 1622 (post-initial-implementation count) = 12 new
tests from the review-fix round (11 for findings 1+2, 1 for finding 3),
all passing; 1634 − 1577 (original baseline) = 57 new tests overall.

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```
```
Building for debugging...
Build complete! (0.57 sec)
```
Exit code `0`.

## Pre-existing failures (review-fix round)

None. The one apparent regression during this round
(`test_detectHandoffs_secondTokenStopsAtPunctuation`) was traced to its own
fixture depending on behavior the fix deliberately tightened, not a defect
introduced elsewhere — fixed by rewriting the fixture, not the
implementation.
