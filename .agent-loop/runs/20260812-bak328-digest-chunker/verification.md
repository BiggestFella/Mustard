# Verification — BAK-328

## Environment note

`swift test` (build-for-testing) failed to compile against the default
Xcode toolchain (`/Applications/Xcode.app`) with errors unrelated to this
change: `cannot find type 'AnalyzerInputConverter' in scope`
(`AppleSpeechSession.swift:294`) and `cannot find type 'LanguageModelError'
in scope` (`OnDeviceLanguageService.swift:208`) — both real macOS 27
Speech/FoundationModels framework symbols the default toolchain's SDK
doesn't expose for the testing build config (`swift build` alone succeeded
against the same toolchain). Confirmed this reproduces identically on a
pristine `origin/main` checkout (stashed my changes, reran) — pre-existing
and unrelated to BAK-328. Per the repo's own history (Xcode 27 beta via
per-shell `DEVELOPER_DIR`), pointed `DEVELOPER_DIR` at
`~/Downloads/Xcode-beta.app/Contents/Developer` (Xcode 27.0, build
27A5194q) for all `swift test`/`swift build` invocations below. This is a
per-command env var, not a persistent system/toolchain change.

## TDD — failing test confirmed before each fix

### 1. Rendered-cost chunker test

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestChunkerTests`

Before the fix (renderedLine added but chunk cost still `tokenCount(segment.text)`):
```
Test Suite 'MeetingDigestChunkerTests' failed ... Executed 8 tests, with 4 failures (0 unexpected)
...MeetingDigestChunkerTests.swift:110: error: ... XCTAssertLessThanOrEqual failed: ("7247") is greater than ("2048")
...MeetingDigestChunkerTests.swift:110: error: ... XCTAssertLessThanOrEqual failed: ("7558") is greater than ("2048")
```
(plus 2 pre-existing-budget tests failing: silence-boundary cut and no-silence cut, both because their expectations were recomputed for the new cost regime ahead of the wiring change)

After the fix (chunk cost = `tokenCount(renderedLine(for:))`, `chunkPrompt` deduplicated):
```
Test Suite 'MeetingDigestChunkerTests' passed ... Executed 8 tests, with 0 failures (0 unexpected)
```

### 2. Budget formula test

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests/test_budget_isRealContextMinusInstructionsMinusOutputReserve`

Before the fix (`budget = contextSize / 2`):
```
MeetingDigestServiceTests.swift:204: error: ... XCTAssertEqual failed: ("3") is not equal to ("1")
- the real budget fits both segments in one chunk; contextSize/2 would have forced a split + reduce
Executed 1 test, with 1 failure (0 unexpected)
```

After the fix (`budget = contextSize - tokenCount(instructions) - outputReserve`):
```
Test Suite 'MeetingDigestServiceTests' passed ... Executed 7 tests, with 0 failures (0 unexpected)
```

## Required checks (final state, all 3 commits applied)

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test`
```
Test Suite 'All tests' passed at 2026-08-12 07:49:xx.
	 Executed 1502 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.485 (7.607) seconds
```
Exit code: `0`

(The 1 skipped test is `SnapshotRenderTests.test_renderScreens` — pre-existing,
gated behind `MUSTARD_SNAPSHOT=1`, unrelated to this change.)

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift build`
```
Build complete! (1.70 sec)
```
Exit code: `0`

## Targeted suites (final state)

- `MeetingDigestChunkerTests`: 8/8 passed
- `MeetingDigestServiceTests`: 7/7 passed
