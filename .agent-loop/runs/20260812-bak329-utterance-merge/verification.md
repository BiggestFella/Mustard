# Verification — BAK-329

## Environment note

Same pre-existing environment gap as BAK-328's run: the default Xcode
toolchain (`/Applications/Xcode.app`, SDKs up to `MacOSX26.5.sdk`) cannot
compile `Sources/MustardKit/Voice/AppleSpeechSession.swift` /
`OnDeviceLanguageService.swift` — `cannot find type 'AnalyzerInputConverter'
in scope` / `cannot find type 'LanguageModelError' in scope` (real macOS 27
Speech/FoundationModels symbols; the plain SDK simply doesn't ship them, so
the `@available(macOS 27.0, *)` guards don't help — the symbol lookup fails
at compile time regardless). Reproduced with **zero diff** against this
branch's tip (both my commits already applied, neither touches those files;
last real edits to them are `0c06e1a`/`b81e486`, already on `origin/main`) —
confirmed pre-existing and unrelated to BAK-329. Every `swift test`/`swift
build` invocation below therefore uses
`DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer` (Xcode
27.0), a per-command env var, not a persistent toolchain change.

## TDD — failing tests confirmed before each change

### 1. `MeetingUtteranceMergeTests` (new unit, no implementation yet)

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingUtteranceMergeTests`

Before `MeetingUtteranceMerge.swift` existed:
```
/Users/.../Tests/MustardTests/MeetingUtteranceMergeTests.swift:181:26: error: cannot find 'MeetingUtteranceMerge' in scope
        let utterances = MeetingUtteranceMerge.utterances(from: segments)
                          `- error: cannot find 'MeetingUtteranceMerge' in scope
error: Build failed
```
(errored at every one of the 11 test methods' call sites — a compile-time
red, not a runtime one, since the type didn't exist)

After implementing `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift`:
```
Test Suite 'MeetingUtteranceMergeTests' passed at 2026-08-12 08:07:08.223.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.007 (0.008) seconds
```

### 2. `MeetingDigestServiceTests/test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged`

Command: `DEVELOPER_DIR=.../Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests/test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged`

Before wiring `MeetingUtteranceMerge` into `MeetingDigestService.digest`:
```
MeetingDigestServiceTests.swift:240: error: -[MustardTests.MeetingDigestServiceTests test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged] : XCTAssertLessThan failed: ("3") is not less than ("2") - merging adjacent same-source segments ahead of chunking must cut the digest call count
Executed 1 test, with 1 failure (0 unexpected)
```
(100 tiny adjacent segments needed 2 chunks even unmerged, but the service —
still chunking raw segments — needed 3 generation calls: 2 map + 1 reduce)

After wiring `digest` to chunk `utterances.map(\.asSegment)`:
```
Test Suite 'MeetingDigestServiceTests' passed at 2026-08-12 08:08:53.832.
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds
```
(the same 100 segments now merge into 1 utterance → 1 generation call, and
the action citing the first constituent's persistent id survives evidence
validation)

## Required checks (final state, both commits applied)

Command: `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test`
```
Test Suite 'All tests' passed at 2026-08-12 08:09:37.678.
	 Executed 1514 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.069 (7.170) seconds
```
Exit code: `0`

(Baseline before this work was 1502 pass / 1 skip; this branch adds 11 tests
in `MeetingUtteranceMergeTests` + 1 in `MeetingDigestServiceTests` = 12,
giving 1514 — the arithmetic matches exactly. The 1 skipped test is the
pre-existing `SnapshotRenderTests.test_renderScreens`, gated behind
`MUSTARD_SNAPSHOT=1`, unrelated to this change.)

Command: `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build`
```
Building for debugging...
[Pre-planning 1 / 153]
[Planning deferred tasks]
Build complete! (1.31 sec)
```
Exit code: `0`

Command (plain toolchain, for completeness — expected to fail, see
Environment note above):
```
error: emit-module command failed with exit code 1 (use -v to see invocation)
/Users/.../Sources/MustardKit/Voice/AppleSpeechSession.swift:294:28: error: cannot find type 'AnalyzerInputConverter' in scope
/Users/.../Sources/MustardKit/Voice/AppleSpeechSession.swift:321:25: error: cannot find 'AnalyzerInputConverter' in scope
/Users/.../Sources/MustardKit/Voice/OnDeviceLanguageService.swift:208:62: error: cannot find type 'LanguageModelError' in scope
```
Exit code: `1` — pre-existing, unrelated to BAK-329 (see Environment note).

## Targeted suites (final state)

- `MeetingUtteranceMergeTests`: 11/11 passed
- `MeetingDigestServiceTests`: 8/8 passed (7 pre-existing + 1 new, all green)
- `MeetingDigestChunkerTests`: unaffected, not modified this run
