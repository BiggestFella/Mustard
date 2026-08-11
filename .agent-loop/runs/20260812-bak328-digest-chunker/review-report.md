# Fresh-context review — BAK-328 (7facfa0..45f0b9d on agent/bak-328-digest-chunker-rendered-cost)

Reviewer: fresh-context sonnet subagent, 2026-08-12. Diff base: `origin/main`
(= `git merge-base HEAD origin/main` = `7facfa0`).

- **Standards: PASS** — `renderedLine(for:)` is pure and lives in `Logic/`
  (`MeetingDigestChunker.swift`); `MeetingDigestService.chunkPrompt` now calls
  it instead of duplicating the rendering, giving cost and prompt-rendering a
  single source of truth (the BAK-328 headline requirement). No UI touched,
  no unrelated refactor — diff is exactly the two source files + their two
  test files + run artifacts. Matches project vocabulary (BAK-328, budget,
  rendered cost).
- **Spec: PASS** — all three statically-checkable acceptance criteria verified
  in code and by test: (1) one source of truth — confirmed by reading both
  call sites; (2) no chunk's rendered prompt exceeds budget — confirmed by
  the new 1,100-segment test and by hand-checking the chunker's greedy-fill
  guard; (3) budget = contextSize − instructions − outputReserve, not
  contextSize/2 — confirmed in `MeetingDigestService.digest` and by
  independently recomputing the new budget test's fixture math (see Test
  axis). The fourth criterion (retrying digest on a real meeting yields a
  summary) is a runtime criterion the issue itself flags as not statically
  reviewable — correctly left unaddressed here. No scope creep: utterance
  merge, partial-digest degradation, and failure-reason persistence
  (BAK-329/330/331) are untouched; the reduction pass is explicitly left
  unbudgeted per task.md's stated design decision, which is reasonable since
  BAK-328 is scoped to the map/chunk path only.
- **Risk: PASS** — touched paths are `Sources/MustardKit/Logic/*.swift`,
  `Sources/MustardKit/Meeting/*.swift` (medium), `Tests/*.swift` (low), plus
  `.agent-loop/runs/...` bookkeeping. No match against any `high` pattern in
  `.agent-loop/risk.yml` (`auth`/`oauth`/`secret`/`ClaudeRunner`/
  `TrustPolicy`/`RecommendationAction`/`.github/workflows/`/`.env`) —
  verified by grepping the changed-file list, not just trusting
  risk-report.md's own claim. Declared class (medium) matches. No outward
  actions; branch not pushed, no PR opened (correctly parked pending this
  review, not "silently parked" work — the dev-loop's own
  `require_fresh_context_review: true` gate is why it stopped here).
- **Test: PASS** — reviewer ran checks independently, not just read
  verification.md:
  - `swift test --filter MeetingDigestChunkerTests` → 8/8 passed, exit 0.
  - `swift test --filter MeetingDigestServiceTests` → 7/7 passed, exit 0.
  - Full `swift test` → 1502 executed, 1 skipped (pre-existing
    `MUSTARD_SNAPSHOT`-gated), 0 failures, exit 0.
  - `swift build` → exit 0.
  - **Reproduced the failing-first claim myself**: checked out commit
    `b621e94` (test added, cost accounting not yet wired) in this worktree,
    reran `MeetingDigestChunkerTests` → 4/8 failed, including
    `test_chunkCost_isTheRenderedPromptLine_notTheRawText` at the exact
    token counts verification.md reports (7247/7558 > 2048) — the new test
    genuinely pins the old bug, not a tautology. Restored HEAD afterward;
    worktree left clean at `45f0b9d`.
  - **Hand-verified the budget-formula test's arithmetic**: with
    `contextSize=4096`, `instructions="DIGEST-INSTRUCTIONS"` (19 chars),
    `outputReserve=1024`: old budget = 2048, new budget = 3053. The two
    padded segments' combined rendered cost is 2166 (prefixes 32+34 chars +
    2×1050 pad) — strictly between 2048 and 3053, exactly as the test's own
    sanity assertions require. The math is a real recomputation, not fudged.
  - Existing chunker regression tests (silence-boundary cut, no-silence
    cut, oversized-single-segment) were re-derived from `cost()` (the real
    `renderedLine` length) instead of stale hardcoded character counts —
    checked each budget expression against the segments in place and
    confirmed the intended cut point is still exercised in each case; no
    coverage was deleted, only budgets recomputed.

## Findings → disposition

1. NON-BLOCKING (test-coupling nit): `MeetingDigestServiceTests.swift`
   (`test_budget_isRealContextMinusInstructionsMinusOutputReserve`) hardcodes
   `let outputReserve = 1024 // mirrors MeetingDigestService.outputReserve`
   instead of referencing `MeetingDigestService.outputReserve` directly —
   the test file already does `@testable import MustardKit`, so direct
   access is available. A future change to the real constant without
   updating this mirror would likely be caught by the fixture's own
   `XCTAssertGreaterThan`/`XCTAssertLessThanOrEqual` sanity checks, so this
   is low-severity, but referencing the real constant would remove even
   that residual risk. No action needed to merge.
2. NON-BLOCKING (follow-up idea): `outputReserve = 1024` is a documented but
   not empirically measured headroom for the structured-generation output +
   date preamble. No test asserts it's actually sufficient for realistic
   `GeneratedMeetingDigest` output sizes. Worth a follow-up if digest output
   ever grows (e.g., long actions lists) — not blocking for this fix, which
   is scoped to the chunk-cost/budget-formula bug.

## Verdict: APPROVE (0 blocking; 2 non-blocking follow-up notes, filed as-is
above rather than a new backlog item since they're minor and low-severity)
