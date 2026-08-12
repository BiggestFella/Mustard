# BAK-334 verification

## Baseline (re-confirmed on `origin/main`, before any change)

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 09:34:51.461.
	 Executed 1559 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.450 (7.554) seconds
Test Suite 'All tests' passed at 2026-08-12 09:34:51.462.
	 Executed 1559 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.450 (7.561) seconds
```
Matches the stated baseline (1559 pass / 1 skip) exactly. Exit code `0`.

## Phase-0 probe compile evidence

`Sources/MustardKit/Voice/_BAK334Probe.swift` (throwaway, exercising
`AnalysisContext`, `.contextualStrings[.general]`, `SpeechAnalyzer.context`,
`SpeechAnalyzer.setContext(_:)`):

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```
```
Building for debugging...
...
Build complete! (5.52 sec)
```
(Only the pre-existing, unrelated `MustardApp.swift:176` Sendable-closure
warning — verified pre-existing by re-checking after deleting the probe.)
Probe file deleted; rebuild afterward:
```
Build complete! (9.25 sec)
```
Same single pre-existing warning, nothing else — the probe left no residue.
Full swiftinterface grep evidence and the API surface it revealed are in
`task.md`.

## Red-first proof — `VoiceLexiconTests.swift`

Written against `VoiceLexicon`/`VoiceLexiconSource` types that did not yet
exist. `swift test --filter VoiceLexiconTests` failed to **compile**:

```
error: cannot find 'VoiceLexicon' in scope
    XCTAssertEqual(VoiceLexicon.parseUserTerms(""), [])
                    ^~~~~~~~~~~~
error: cannot find 'VoiceLexiconSource' in scope
    let lexicon = VoiceLexiconSource.fetch(context: ctx, now: now, userTerms: [])
                  ^~~~~~~~~~~~~~~~~~
error: cannot find 'VoiceLexiconSource' in scope
    let lexicon = VoiceLexiconSource.fetch(context: ctx, now: .now, userTerms: ["Cavehole"])
                  ^~~~~~~~~~~~~~~~~~
```
Confirmed red before `Sources/MustardKit/Logic/VoiceLexicon.swift` and
`Sources/MustardKit/Voice/VoiceLexiconSource.swift` were written.

After implementing both files:
```
Test Suite 'VoiceLexiconTests' passed at 2026-08-12 09:49:01.138.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.034 (0.035) seconds
```
All 18/18 green, exit `0`.

## Session-wiring compile verification

`VoiceTranscribing` gained a `setContext(_:)` requirement with a default
no-op extension specifically so existing conformers wouldn't need edits.
Verified by building the whole package (not just the new files) —
`MeetingTranscriptMergeTests.swift`'s `StubSession` and
`MeetingCaptureCoordinatorTests.swift`'s `StubSession`/
`MeetingSessionAlwaysInsufficient` compiled unchanged, satisfied by the
protocol extension's default implementation.

## After implementation — full suite

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
```
```
Test Suite 'MustardTests.xctest' passed at 2026-08-12 09:46:48.455.
	 Executed 1577 tests, with 1 test skipped and 0 failures (0 unexpected) in 10.752 (10.860) seconds
Test Suite 'All tests' passed at 2026-08-12 09:46:48.455.
	 Executed 1577 tests, with 1 test skipped and 0 failures (0 unexpected) in 10.752 (10.866) seconds
```
Re-run separately to capture the exit code explicitly:
```
$ DEVELOPER_DIR=... swift test > /tmp/test_full_output.log 2>&1; echo "EXIT CODE: $?"
EXIT CODE: 0
	 Executed 1577 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.513 (7.624) seconds
```
1577 = 1559 baseline + 18 new (`VoiceLexiconTests`). 1 skip unchanged
(pre-existing, unrelated to this change — same skip present at baseline).

```
$ DEVELOPER_DIR=... swift build > /tmp/build_full_output.log 2>&1; echo "EXIT CODE: $?"
EXIT CODE: 0
Building for debugging...
Build complete! (0.29 sec)
```

## New test inventory (18, `Tests/MustardTests/VoiceLexiconTests.swift`)

- Rank order: userTerms → areas → taskLists → proposalOwners → title-derived
  (1 test, ordering assertion across all five categories).
- Case-insensitive dedup, first occurrence's casing wins (1 test — userTerms
  casing survives over area/list mentions of the same word).
- Title heuristic positives: acronym-style singleton (`DLA`), a second
  acronym-style singleton (`CDSB`), repeated capitalized word across two
  titles (`Thales`) (3 tests).
- Title heuristic negatives: sentence-initial stopword (`Fix`), a batch of
  common stopwords (`Add`, `New`, `Update`, `The`), a singleton capitalized
  non-acronym word (`Priya`) (3 tests).
- Length bounds: too-short (1 char) dropped, too-long (41 chars) dropped, a
  40-char term kept (2 tests).
- Cap enforcement: default is 100; a 20-area input capped to 5 (2 tests).
- User terms survive the cap even when other categories alone would exceed
  it (1 test).
- Empty inputs → empty result (1 test).
- `parseUserTerms`: splits on comma/newline, trims, drops empties; empty
  string → empty (2 tests).
- Fetch-assembly seam (`VoiceLexiconSource.fetch`) against an in-memory
  `ModelContainer`: gathers area/list names, a task title created 1 hour
  ago, and a meeting-action owner; excludes a task title from a task created
  120 days ago (outside the 90-day window); user terms rank first (2 tests).
