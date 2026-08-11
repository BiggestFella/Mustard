# Verification — BAK-330 + BAK-331

## Environment note

Same pre-existing environment gap documented in the BAK-328/BAK-329 runs:
the default Xcode toolchain (`/Applications/Xcode.app`) cannot compile
`Sources/MustardKit/Voice/AppleSpeechSession.swift` /
`OnDeviceLanguageService.swift` — `cannot find type 'AnalyzerInputConverter'
in scope` / `cannot find type 'LanguageModelError' in scope` (real macOS 27
Speech/FoundationModels symbols the plain SDK doesn't ship). Reproduced
again at the end of this run with a plain `swift build` (no `DEVELOPER_DIR`
override) — the errors are confined to those two files, neither touched by
this work, confirming the gap is unrelated. Every `swift test`/`swift build`
below uses `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer`
(Xcode 27 beta), a per-command env var, not a persistent toolchain change.

## TDD — failing tests confirmed before each change

### 1. `MeetingDigestFailureReasonTests` (new file; `MeetingDigestFailureReason`
   and `MeetingDigest.omissionNote` did not exist yet)

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestFailureReasonTests`

Before implementation — compile-time red at every call site:
```
error: type 'MeetingDigest' has no member 'omissionNote'
```
(and the equivalent `cannot find type 'MeetingDigestFailureReason' in scope`
at the mapping call sites)

After adding `MeetingDigestFailureReason` + `MeetingDigest.omissionNote(spans:)`
to `Sources/MustardKit/Logic/MeetingDigestChunker.swift`:
```
Test Suite 'MeetingDigestFailureReasonTests' passed at 2026-08-12 08:28:09.651.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds
```

### 2. `MeetingDigestServiceTests` — BAK-330 partial-degradation tests

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests`

Before touching `MeetingDigestService.digest`'s map loop (3 of the 4 new
tests red — the old all-or-nothing abort behavior didn't match):
```
test_allChunksFail_returnsTheLastChunkFailure_asATypedFailure : failed - expected the LAST chunk's failure (.contextOverflow), got failure(...modelNotReady)
test_lastChunkFails_earlierSuccessesSurvive_reduceCombinesThem : failed: caught error: "model(...contextOverflow)"
test_middleChunkFails_othersSurvive_asAPartialDigestWithOmittedSpan : failed: caught error: "model(...modelNotReady)"
Executed 12 tests, with 3 failures (2 unexpected)
```
(`test_reduceFailure_stillFailsTheWholeDigest_knownLimitation` was already
green under the OLD behavior too — a reduce failure aborted then and still
aborts now, so that assertion never needed the code to change; it stays as
a regression guard for the documented limitation.)

After making the map loop collect partials instead of aborting on the first
failure:
```
Test Suite 'MeetingDigestServiceTests' passed at 2026-08-12 08:30:51.742.
	 Executed 12 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
```

### 3. `MeetingRecordModelTests` — BAK-330/331 model fields

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingRecordModelTests`

Before adding the fields — compile-time red:
```
error: value of type 'MeetingRecord' has no member 'digestFailureReason'
error: value of type 'MeetingRecord' has no member 'digestFailureReasonRaw'
```

After adding `MeetingDigestStatus.partial`, `digestOmissionNote`,
`digestFailureReasonRaw` + the typed `digestFailureReason` accessor to
`Sources/MustardKit/Models/MeetingRecord.swift` (and, forced by the
non-exhaustive switch this created, the minimal `.partial`/`.failed` case
handling in `MeetingReviewView.digestSection` — see task.md's "Files
touched" note):
```
Test Suite 'MeetingRecordModelTests' passed at 2026-08-12 08:32:37.837.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.043 (0.044) seconds
```

### 4. `MeetingCaptureCoordinatorTests` — BAK-330/331 coordinator persistence

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests`

Before adding `applyDigestFailure` and the omission-note/status wiring to
`applyDigest` — 5 new tests red (reasons and notes stayed `nil`, status
stayed `.ready` instead of `.partial`):
```
test_digestFailure_persistsTheMappedReason : ("nil") is not equal to ("Optional(...deviceNotEligible)") - the failure reason is mapped and persisted alongside .failed
test_digestRetry_thatFails_persistsTheNewMappedReason : ("nil") is not equal to ("Optional(...modelNotReady)")
test_digestRetry_thatFails_persistsTheNewMappedReason : ("nil") is not equal to ("Optional(...contextOverflow)") - a retry that fails differently updates the persisted reason
test_digestWithOmittedSpans_persistsPartialStatus_andAnOmissionNote : ("ready") is not equal to ("partial") - an omitted span degrades ready to partial
test_digestWithOmittedSpans_persistsPartialStatus_andAnOmissionNote : ("nil") is not equal to ("Optional("14:12–19:03 into the meeting could not be summarised.")")
test_successfulDigest_clearsAPreviouslyPersistedFailureReason : ("nil") is not equal to ("Optional(...appleIntelligenceDisabled)")
Executed 16 tests, with 6 failures (0 unexpected)
```
(the 6th failure line is the second assertion inside
`test_digestRetry_thatFails_persistsTheNewMappedReason`)

After wiring `applyDigestFailure` (persists the mapped reason, logs its
rawValue, sets `.failed`) and updating `applyDigest` (clears the reason,
sets `.partial`/note when `omittedSpans` is non-empty):
```
Test Suite 'MeetingCaptureCoordinatorTests' passed at 2026-08-12 08:33:52.687.
	 Executed 16 tests, with 0 failures (0 unexpected) in 0.295 (0.296) seconds
```

## Required checks (final state, all commits applied)

Command: `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test`
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 08:36:08.256.
	 Executed 1539 tests, with 1 test skipped and 0 failures (0 unexpected) in 10.265 (10.369) seconds
Test Suite 'All tests' passed at 2026-08-12 08:36:08.256.
	 Executed 1539 tests, with 1 test skipped and 0 failures (0 unexpected) in 10.265 (10.375) seconds
```
Exit code: `0`

(Baseline before this work was 1514 pass / 1 skip. This branch adds 13 tests
in `MeetingDigestFailureReasonTests` + 4 in `MeetingDigestServiceTests`
(BAK-330) + 3 in `MeetingRecordModelTests` + 5 in
`MeetingCaptureCoordinatorTests` = 25, giving 1539 — matches exactly. The 1
skipped test is the pre-existing `SnapshotRenderTests.test_renderScreens`,
gated behind `MUSTARD_SNAPSHOT=1`, unrelated to this change.)

Command: `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build`
```
Building for debugging...
[3 / 15] Mustard_MustardKit
Build complete! (0.46 sec)
```
Exit code: `0`

Command (plain toolchain, for completeness — expected to fail, see
Environment note above):
```
error: emit-module command failed with exit code 1 (use -v to see invocation)
Sources/MustardKit/Voice/AppleSpeechSession.swift:294:28: error: cannot find type 'AnalyzerInputConverter' in scope
Sources/MustardKit/Voice/AppleSpeechSession.swift:321:25: error: cannot find 'AnalyzerInputConverter' in scope
Sources/MustardKit/Voice/OnDeviceLanguageService.swift:208:62: error: cannot find type 'LanguageModelError' in scope
```
Exit code: `1` — pre-existing, unrelated to this work (see Environment note;
neither erroring file was touched by BAK-330/BAK-331).

## Targeted suites (final state)

- `MeetingDigestFailureReasonTests`: 13/13 passed
- `MeetingDigestServiceTests`: 12/12 passed (8 pre-existing + 4 new, all green)
- `MeetingDigestChunkerTests`: unaffected, not modified this run
- `MeetingRecordModelTests`: 13/13 passed (10 pre-existing + 3 new)
- `MeetingCaptureCoordinatorTests`: 16/16 passed (11 pre-existing + 5 new)

## Coordinator-level test coverage note

All BAK-330/331 coordinator assertions were injectable via the existing
`generateDigest` closure parameter on `MeetingCaptureCoordinator` (the same
seam `MeetingCaptureCoordinatorTests` already used for the pre-existing
digest-failure/success tests) — no coordinator test had to be skipped or
worked around.
