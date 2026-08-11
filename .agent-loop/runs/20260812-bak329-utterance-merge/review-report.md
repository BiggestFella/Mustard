# Fresh-context review — BAK-329 (agent/bak-329-utterance-merge)

Diff base: `origin/main` (3 commits: `2a0dff0`, `8cba26f`, `413fa24`).
Files touched: `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift` (new),
`Sources/MustardKit/Meeting/MeetingDigestService.swift`,
`Tests/MustardTests/MeetingUtteranceMergeTests.swift` (new),
`Tests/MustardTests/MeetingDigestServiceTests.swift`, plus this run's own
`.agent-loop/runs/20260812-bak329-utterance-merge/` artifacts.

## Standards Review — PASS

- New decision logic lives in `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift`,
  a pure enum/struct with no side effects, matching the repo's `Logic/` convention.
- One test file per unit: `MeetingUtteranceMergeTests.swift` for the new unit;
  the existing `MeetingDigestServiceTests.swift` got one new test for the
  caller-side wiring, in place, not a new file (correct — it's the same unit).
- The caller diff (`MeetingDigestService.swift`) is a genuinely minimal,
  surgical change: 7 added lines (comment + 2 statements), no line removed
  except the one it replaces. No unrelated refactors anywhere in the diff.
- Style matches neighboring code: doc comments explain the "why" (BAK-329,
  the 1,145-segment standup numbers), `Equatable, Sendable` on the value type,
  computed properties mirroring `MeetingTranscriptMerge`'s idioms.
- No shallow-module smell: `MeetingUtteranceMerge` has one clear
  responsibility (segment → utterance grouping) and a narrow public surface
  (`utterances(from:...)`, plus `MeetingUtterance`'s four computed views).

## Spec Review — PASS

Checked each BAK-329 acceptance criterion directly against code, not just the
task.md checklist:

- **Digest input is utterances, not raw finals.** Confirmed:
  `MeetingDigestService.digest` (line ~113) builds
  `let utterances = MeetingUtteranceMerge.utterances(from: segments)` and
  feeds `utterances.map(\.asSegment)` into `MeetingDigestChunker.chunks`,
  replacing the old direct `segments` argument.
- **Merging only joins same-source segments; interleaving preserved, never
  reordered.** Confirmed by reading `utterances(from:)`: the loop only
  extends `current` when `segment.source == previous.source`; any other
  source always starts a new one-element run via `result.append(...)` /
  `current = [segment]`, and segments are consumed in the exact order given
  — no sort, no reorder. Traced the two-source interleaved case by hand
  (`[mic a1, meeting m1, mic a2]` → three separate one-segment utterances,
  order `[a1, m1, a2]` preserved) and it matches
  `test_otherSourceSegmentBetween_breaksTheRun_orderPreserved`, which asserts
  exactly this.
- **Every merged utterance exposes its constituent segment ids.**
  `MeetingUtterance.segmentIDs` maps every constituent through
  `MeetingTranscriptMerge.persistentID(for:)`, in order; tested by
  `test_segmentIDs_arePersistentIDsOfEveryConstituent_inOrder`.
- **Evidence validation still resolves to a real persisted segment id
  (the flagged CRITICAL check).** Traced the full chain:
  - `validIDs` in `MeetingDigestService.digest` (line 148) is built from the
    **original** `segments` parameter, untouched by this diff.
  - `MeetingUtterance.asSegment` sets `id: segments[0].id` — the first
    constituent's **raw** id (not a synthesized/namespaced one) — and
    `source: source`, which is `segments[0].source`. Both the id and the
    source of the first constituent are preserved unmodified onto `asSegment`.
  - `MeetingDigestChunker.renderedLine(for:)` (what the model sees and cites)
    computes `MeetingTranscriptMerge.persistentID(for: segment)` =
    `"\(segment.source.rawValue):\(segment.id)"`. For `asSegment` this equals
    `"\(segments[0].source.rawValue):\(segments[0].id)"`, i.e. exactly
    `MeetingTranscriptMerge.persistentID(for: segments[0])` — a real,
    persisted id that is a member of `validIDs`.
  - So an action citing a merged utterance's id resolves to the first real
    constituent segment, and evidence validation passes. This is also
    exercised end-to-end by
    `MeetingDigestServiceTests.test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged`,
    which asserts `digest.actions.first?.evidenceSegmentIDs == [pid(segments[0])]`
    after a real merge-then-digest run. I ran this test myself (see below);
    it passes.
- **Persisted transcript unchanged.** The diff never mutates or writes
  `segments`; `MeetingUtteranceMerge` and `.asSegment` are pure, read-only
  transforms computed at digest time. No `@Model`/SwiftData schema touched,
  no migration added. Confirmed by diff inspection (`MeetingCaptureCoordinator.swift`,
  `MeetingTranscriptMerge.swift`, and all persistence code are absent from
  the diff).

No scope creep: `MeetingDigestChunker.swift` (chunker internals),
`MeetingDigestFailure`/failure surfacing, and the reduction/partial-digest
path are all untouched by this diff — confirmed by `git diff --stat`, which
shows only the four source/test files plus run artifacts.

## Risk Review — PASS

Per `.agent-loop/risk.yml` `path_risk`:
- `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift` and
  `Sources/MustardKit/Meeting/MeetingDigestService.swift` match `Sources/` →
  **medium**.
- Both test files match `Tests/` → **low**.
- No path matches any `high` pattern (`auth`, `oauth`, `secret`,
  `ClaudeRunner`, `TrustPolicy`, `RecommendationAction`,
  `.github/workflows/`, `.env`) — confirmed by grepping the full file list
  against those substrings, no hits besides the risk-report's own prose.
- Declared risk class in `risk-report.md` (medium) matches the actual diff.
- No outward actions: no git tags/releases, no remote-ref deletions, no
  secret rotation, no force push, no network/email/Slack/ticket calls. Branch
  is local-only (`git status` shows 3 commits ahead of `origin/main`, not
  pushed), matching the risk report's claim.

## Test Review — findings below; otherwise PASS

Ran all three specified commands myself against the worktree
(`DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer`):

- `swift test --filter MeetingUtteranceMergeTests` → **11/11 passed**, exit 0.
- `swift test --filter MeetingDigestServiceTests` → **8/8 passed**, exit 0.
- `swift test` (full suite) → **1514 executed, 1 skipped (pre-existing
  `SnapshotRenderTests.test_renderScreens`, gated behind `MUSTARD_SNAPSHOT=1`),
  0 failures**, exit 0.
- `swift build` → **Build complete**, exit 0.

All of these match verification.md's claims exactly (I independently
reproduced them, not just re-read the file).

Tests do cover observable behavior through the public interface
(`utterances(from:)`, `.asSegment`, `.segmentIDs`, and the service's
`digest(segments:now:)`), and the realistic 1,100-segment fixture proves the
merge collapses dramatically (asserted `< 25%` of original count) and that no
utterance exceeds the cap.

### NON-BLOCKING — quadratic-recompute risk is real in shape but unproven by a test

`Sources/MustardKit/Logic/MeetingUtteranceMerge.swift:93-96`: every candidate
segment addition recomputes `MeetingUtterance(segments: candidate).text.count`
over the **entire current run**, not just the new segment. This is
genuinely O(k²) in characters scanned per run of length k. I reasoned through
whether this can blow up: a run's length k is naturally bounded by
`maxTextLength` (2,000 chars) divided by the smallest per-segment
contribution (~15-16 chars for typical transcriber finals, or as low as ~2
chars for pathological 1-character segments), because once the running text
exceeds the cap the run is forced to flush. So k is a bounded constant, not a
function of total transcript size, and the algorithm is linear in total
segment count with a small constant factor even in the worst realistic case
(~1,000-segment single-source monologue with no pause). This is not a
correctness bug. But the existing realistic-transcript test
(`test_realisticTranscript_collapsesDramatically`, 1,100 segments) breaks
runs every ~20 segments via alternating source/occasional pauses — it never
exercises a single continuous same-source run anywhere near the
`maxTextLength` boundary, so nothing in the suite actually demonstrates the
bound holds or that a near-cap run completes fast. Recommend a follow-up
test: one continuous same-source run of ~130+ short segments (or ~1,000
single-character segments) with no pause break, asserting it completes and
splits correctly.

### NON-BLOCKING — untested edge: a single raw segment whose own text already exceeds `maxTextLength`

Checked `Tests/MustardTests/MeetingUtteranceMergeTests.swift` for this case —
absent. `test_maxTextLength_splitsRatherThanExceeding` only exercises a run
that *grows past* the cap across multiple segments; no fixture starts with a
single segment whose own `text` is already over 2,000 characters.

I traced the code manually for this case: `current` is unconditionally
seeded with `[segments[0]]` regardless of its size (the `maxTextLength` guard
only gates whether to **add another** segment to an existing candidate). So
an oversized first segment is never dropped and never causes a loop — the
next iteration's `candidate` (already ≥ the oversized text) fails the
`<= maxTextLength` check immediately, flushing the oversized segment as its
own one-element utterance and starting a fresh run with the next segment. If
the oversized segment is the only or last segment, the post-loop
`result.append(MeetingUtterance(segments: current))` still emits it. This
mirrors `MeetingDigestChunker`'s own "an oversized single segment lands alone
in its own chunk" behavior and appears correct by inspection, but the
behavior is currently asserted nowhere. Recommend a follow-up test: one
segment with `text.count > maxTextLength` (alone, and again followed by a
same-source in-pause segment), asserting exactly one utterance is produced
for it and its text is preserved (not dropped or truncated).

Neither finding blocks correctness of the shipped behavior; both are test-
coverage gaps worth closing before this code sees a real pathological
transcript in production.

## Verdict

`VERDICT: mergeable`

Both findings above are NON-BLOCKING coverage gaps, not correctness defects
— I verified by code inspection that both edges behave correctly today. No
BLOCKING findings on any axis.

## Commands run and outcomes

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer \
  swift test --filter MeetingUtteranceMergeTests
  → 11/11 passed, exit 0

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer \
  swift test --filter MeetingDigestServiceTests
  → 8/8 passed, exit 0

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer \
  swift test
  → 1514 executed, 1 skipped, 0 failures, exit 0

DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer \
  swift build
  → Build complete, exit 0

git diff origin/main..HEAD --stat / --name-only
  → confirms only the 4 declared source/test files + run artifacts changed

grep of path_risk high-risk substrings against the changed-file list
  → no matches; confirms medium/low classification in risk-report.md
```
