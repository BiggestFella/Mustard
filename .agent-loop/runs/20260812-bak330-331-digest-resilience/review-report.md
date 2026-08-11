# Fresh-context review — BAK-330 / BAK-331 digest resilience

Branch `agent/bak-330-331-digest-resilience`, diff base `origin/main` (4 commits:
e7998a8, 0090592, 2bbae80, fb18556). No prior context on this work; everything
below was verified directly against the diff, the run artifacts, and actual
command output.

## Standards — PASS

- Decisions live in `Logic/`: `MeetingDigestFailureReason` (failure→reason
  mapping, `userMessage`, `offersRetry`) and `MeetingDigest.omissionNote(spans:)`
  are pure, sit next to `MeetingDigestFailure`/`MeetingDigest` in
  `Sources/MustardKit/Logic/MeetingDigestChunker.swift`, and are unit-tested in
  isolation (`MeetingDigestFailureReasonTests.swift`).
- `Sources/MustardKit/Views/MeetingReviewView.swift`'s `digestSection` is
  render-only: it switches on already-computed state (`digestStatus`,
  `digestFailureReason?.offersRetry`, `digestOmissionNote`) and dispatches
  `retryDigest`; no new decision logic in the view.
- Theme tokens only — the new failure/omission captions reuse
  `Theme.Fonts.caption` / `Theme.Palette.textSecondary`, matching the
  pre-existing failure caption's styling exactly. No hardcoded colors.
- SwiftData model change verified safe: `MeetingRecord` gains two **optional**
  stored properties (`digestOmissionNote: String?`, `digestFailureReasonRaw:
  String?`) and `MeetingDigestStatus` gains one case (`.partial`) on a
  `String`-raw `Codable` enum. No `VersionedSchema`/`SchemaMigrationPlan` exists
  anywhere in `Sources/` (grepped, zero hits) — the container relies on
  SwiftData's automatic lightweight migration, and both changes are within its
  bounds (additive optional properties, additive enum case on a string-backed
  enum). Confirmed `MeetingDigestStatus(rawValue:) ?? .pending` at
  `Sources/MustardKit/Models/MeetingRecord.swift:80` is unchanged and still
  falls back to `.pending` for any unrecognized raw value (including a value
  from a build newer than the reader). `digestFailureReason`'s getter
  (`MeetingRecord.swift:84-87`) has the same forward-compatible fallback to
  `nil`, and this is directly tested
  (`MeetingRecordModelTests.test_digestFailureReason_unknownRawValue_decodesAsNil`).
- No unrelated refactors. Diff is scoped to the meeting-digest subsystem (5
  source files, 4 test files) plus the run's own artifacts.

## Spec — PASS (two NON-BLOCKING scope notes)

**BAK-330** — all five stated criteria verified in code and tests:
- One failed chunk of N degrades to a digest built from the other N−1:
  `MeetingDigestService.digest`'s map loop (`MeetingDigestService.swift:124-137`)
  no longer returns `.failure` on the first bad chunk; it records the chunk's
  span into `omittedSpans` and continues.
- Complete vs partial is distinguished by a new status case:
  `MeetingDigestStatus.partial` (`MeetingRecord.swift:16`), set in
  `applyDigest` (`MeetingCaptureCoordinator.swift:355`) exactly when
  `omittedSpans` is non-empty.
- Review UI names the missing part in time terms: `MeetingDigest.omissionNote`
  renders `mm:ss–mm:ss into the meeting could not be summarised.`, surfaced in
  `MeetingReviewView` when `digestStatus == .partial`.
- Zero successful chunks still fails: `MeetingDigestService.swift:143-145`
  returns `.failure` (the last chunk's failure) when `chunks` is non-empty but
  every chunk failed; an empty transcript (`chunks.isEmpty`) is unaffected and
  still falls through to the pre-existing empty-summary success path.
- Recording/transcript untouched in every path: transcript segments are
  persisted unconditionally in `MeetingCaptureCoordinator.stop()`
  (`MeetingCaptureCoordinator.swift:202-212`) *before* digest generation is
  ever attempted, regardless of outcome — confirmed by reading the call order.

**BAK-331** — all four stated criteria verified:
- Failure reason persists across relaunch: `digestFailureReasonRaw: String?`
  on `MeetingRecord`, written by `applyDigestFailure` and saved via
  `context.save()`.
- Review panel shows the specific reason, generic line as fallback only:
  `MeetingReviewView.swift` (`meeting.digestFailureReason?.userMessage ?? "…generic…"`).
- Retry gated per reason via `offersRetry`, not offered blanket for `.failed`.
- Reason logged via `voiceLog.error("meeting: digest failed reason=\(reason.rawValue, privacy: .public)")`
  — rawValue only. `LocalModelFailure.unavailable`'s associated detail string
  is deliberately dropped by `MeetingDigestFailureReason.init(failure:)` before
  it ever reaches persistence or logging.

**Deliberate deviation** (`appleIntelligenceDisabled` offers retry, against
the ticket's "known permanent cause → no retry" table): judged **sound**.
Once Leon flips the System Settings switch, retry is the actual fix — treating
it as a permanent, non-retryable cause the way `deviceNotEligible` is would be
wrong. It's transparently documented in three places (code comment on
`offersRetry`, a dedicated test
`test_appleIntelligenceDisabled_offersRetry_deliberateDeviation`, and
`risk-report.md`'s "Notes" section flagging it explicitly for reviewer
attention). Not a blocker.

**NON-BLOCKING scope note**: a reduce-phase failure (when ≥2 chunks succeed
individually but the single reduction pass over their partials throws) still
discards every successfully-generated partial and all of `omittedSpans`
(`MeetingDigestService.swift:157-163`, `return .failure(failure)`). This is a
distinct failure mode from "one failed chunk" and BAK-330's acceptance
criteria are worded specifically about chunk failures, so this isn't a literal
AC violation — but it means the same user-facing complaint ("I lost content
that had already been summarised") can still occur via this second path. It's
explicitly acknowledged as a "known limitation" in a code comment
(`MeetingDigestService.swift:148-150`) and has a dedicated regression test
(`test_reduceFailure_stillFailsTheWholeDigest_knownLimitation`) — documented
and tested, not hidden. Worth a follow-up ticket, not a merge blocker.

## Risk — PASS

Per `.agent-loop/risk.yml`: every touched path is under `Sources/` (medium) or
`Tests/`/`.agent-loop/` (low); none match a `high` pattern
(`.github/workflows/`, `.env`, `secret`, `auth`, `oauth`, `ClaudeRunner`,
`TrustPolicy`, `RecommendationAction` — grepped, zero hits in the diff).
`risk-report.md`'s **medium** classification matches. No outward actions (no
tags, releases, force pushes, remote-ref deletions, secret rotation) — the
branch was not pushed and no PR opened, matching the run's stated instruction.

Specifically traced the two clobbering risks called out for this review:

- **`errorMessage` clobbering.** Grepped `MeetingCaptureCoordinator.swift` for
  every `record.errorMessage` write: only `interrupt()` (line 326) and
  `fail()` (line 318) and `recoverOnLaunch()` (line 295) touch it — all
  pre-existing, recording-lifecycle-only code paths. Neither `applyDigest` nor
  the new `applyDigestFailure` reference `errorMessage` at all. The digest
  lifecycle and the recording lifecycle remain fully decoupled, as the
  pre-existing doc comment on `MeetingDigestStatus` promises.
- **`applyDigestFailure` on a `.partial`-then-retry path.** Traced
  `retryDigest`'s guard (`MeetingCaptureCoordinator.swift:244`):
  `record.digestStatus == .failed || record.digestStatus == .pending`.
  `.partial` is **excluded** — a partial digest cannot currently be retried
  through any public entry point (the view also renders `EmptyView()` for
  `.partial`, offering no Retry button). This means the specific scenario
  ("a retry that fails after a prior partial success") is **unreachable** in
  the current code, not merely handled gracefully. Even in the hypothetical
  where a future change loosened that guard: `applyDigestFailure`
  (`MeetingCaptureCoordinator.swift:362-367`) only ever writes
  `digestFailureReasonRaw` and `digestStatusRaw` — it never touches
  `summaryText`, `decisions`, `unresolvedQuestions`, or `proposals` — so a
  good digest's content would not be wiped even if that path became reachable.
  **NON-BLOCKING forward-looking note**: `MeetingReviewView.digestSection`'s
  body (`Views/MeetingReviewView.swift:358-361`) shows `meeting.summaryText`
  whenever it's non-empty, *before* checking `digestStatus == .failed`. If the
  retry guard were ever loosened to allow retrying `.partial`, a failed retry
  would leave `digestStatus == .failed` with the OLD partial `summaryText`
  still present, and the view would silently keep showing that stale content
  instead of the failure message — no data loss, but a misleading display.
  Not a live bug today; flagging only because the review brief asked this
  exact question to be traced to a concrete conclusion.

## Tests — PASS (one NON-BLOCKING coverage gap)

All commands re-run independently (not just re-reading `verification.md`) and
confirmed to match its claims exactly:

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestFailureReasonTests
→ Executed 13 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests
→ Executed 12 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
→ Executed 16 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingRecordModelTests
→ Executed 13 tests, with 0 failures (0 unexpected)

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
→ Executed 1539 tests, with 1 test skipped and 0 failures (0 unexpected), exit 0

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
→ Build complete!, exit 0
```

The 1 skip is the pre-existing `MUSTARD_SNAPSHOT=1`-gated snapshot test,
unrelated to this change. All counts and pass/fail outcomes match
`verification.md` exactly.

The omission-note formatter's >1h coverage is real:
`test_omissionNote_rollsPastOneHour_withoutWrappingToHours`
(`MeetingDigestFailureReasonTests.swift:103-109`) asserts `3661.0...3900.0` →
`"61:01–65:00 into the meeting could not be summarised."`, confirming minutes
roll past 60 rather than wrapping into an `h:mm:ss` display. Verified passing.

**NON-BLOCKING**: the two new partial-degradation tests that are supposed to
prove surviving content flows through to the final digest —
`test_middleChunkFails_othersSurvive_asAPartialDigestWithOmittedSpan`
(`MeetingDigestServiceTests.swift:274-295`) and
`test_lastChunkFails_earlierSuccessesSurvive_reduceCombinesThem`
(`MeetingDigestServiceTests.swift:297-312`) — only assert
`digest.summary == "Combined summary."`, a value hard-coded into the stub's
4th queued result and returned regardless of what the reduction prompt
actually contained. Neither test inspects `stub.recorder.prompts` for the
survivors' real text ("Part one."/"Part three."). This matters because the
file already has the pattern for doing this correctly: the pre-existing
`test_oversizedTranscript_mapsPerChunk_thenReduces`
(`MeetingDigestServiceTests.swift:168`) asserts
`stub.recorder.prompts[2].contains("Part one.")` — i.e. it actually opens the
reduction prompt and checks the survivor's content is in it. The new tests'
inline comment ("the reduction sees only the successful partials") is
asserted by *implication* (chunk count via
`stub.recorder.prompts.count == 4`, `"3 map attempts (one throws) + 1
reduction over the 2 survivors"`) but never directly verified. Reading the
implementation confirms the behavior is actually correct — `partials` is only
ever appended to on `.success`
(`MeetingDigestService.swift:129-130`), so the reduction prompt is provably
built from real survivors — but the test doesn't prove it the way its
sibling does. Recommend tightening these two tests to assert on prompt
content before/instead of relying on the stubbed summary string, as a
follow-up — not a merge blocker, since the underlying behavior is correct and
covered indirectly (span/count assertions) plus the full suite is green.

## Verdict

**VERDICT: mergeable**

All four axes pass; three findings are NON-BLOCKING (scope note on
reduce-phase failures, a forward-looking display-staleness note that is
currently unreachable, and a test-content-assertion gap where the sibling
pattern already exists in the same file). No BLOCKING findings.

### Commands run

```
git status / git branch --show-current / git log --oneline -15
git diff origin/main..HEAD --stat
git diff origin/main..HEAD -- Sources/
git diff origin/main..HEAD -- Tests/MustardTests/MeetingDigestServiceTests.swift
git diff origin/main..HEAD -- Tests/MustardTests/MeetingRecordModelTests.swift
grep -rn "retryDigest\|digestStatus" Sources/ Tests/
grep -n "errorMessage" Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift
grep -n "prompts\[" Tests/MustardTests/MeetingDigestServiceTests.swift
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestFailureReasonTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingRecordModelTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
```
