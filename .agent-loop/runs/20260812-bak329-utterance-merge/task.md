# BAK-329: merge adjacent same-source transcript segments into utterances before digest

## Issue summary

The live transcriber emits near-word-level finals: a real 23-minute standup
persisted 1,145 `VoiceTranscriptSegment`s for 3,176 words (~15 chars each).
`MeetingDigestChunker.renderedLine(for:)` (BAK-328) costs each segment's
rendered prompt line at a ~44-char id/timing prefix plus its text, so with
segments this short ~75% of the rendered prompt was bookkeeping, not
transcript. The chunker and budget formula (BAK-328) are correct given their
input; the input itself is unnecessarily fine-grained.

## Design decisions (given, followed as specified)

1. **New pure unit `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift`.**
   `MeetingUtterance` wraps `[VoiceTranscriptSegment]` (≥1, same source,
   time-ordered) with computed `source`, `startSeconds`/`endSeconds`
   (first/last), `text` (trimmed constituent texts, empties skipped, joined
   with a single space), `segmentIDs` (persistent id of every constituent,
   via `MeetingTranscriptMerge.persistentID`), and `asSegment` (a single
   `VoiceTranscriptSegment` view: id = FIRST constituent's RAW id, span
   covers the whole run, text = merged text, confidence = mean of
   constituents that reported one, `isFinal = true`).
2. **Merge rule.** `MeetingUtteranceMerge.utterances(from:pauseThreshold:maxTextLength:)`
   iterates segments in the given (time-sorted) order. A run extends only
   while the next segment shares the current run's `source`, starts less
   than `pauseThreshold` (1.5s) after the run's last segment ends, and the
   merged text would still fit `maxTextLength` (2,000 chars — breaks
   pathological monologues so no utterance can approach the context window
   alone). Any other-source segment breaks the run without reordering —
   interleaving between sources is preserved.
3. **Wired into `MeetingDigestService.digest(segments:now:)`.** After
   capabilities/instructions resolve and the budget is computed, utterances
   are built from the ORIGINAL `segments` parameter and
   `utterances.map(\.asSegment)` feeds the chunker/prompt path in place of
   the raw segments. `validIDs` for evidence validation is still built from
   the ORIGINAL `segments` — the model cites first-constituent ids (real
   persisted ids), so every cited id remains valid evidence. `retryDigest`
   in the coordinator is untouched (it already passes persisted segments;
   merging happens inside the service).

## Acceptance criteria checklist

- [x] `MeetingUtterance` + `MeetingUtteranceMerge` added, pure, matching the
      given API exactly (`pauseThreshold = 1.5`, `maxTextLength = 2_000`).
- [x] Failing tests written first in
      `Tests/MustardTests/MeetingUtteranceMergeTests.swift` (pause
      merge/split, other-source interleaving, text join/trim/empty-skip,
      maxTextLength split, segmentIDs, asSegment id/span/confidence, empty
      input, realism collapse) — confirmed red (`cannot find
      'MeetingUtteranceMerge' in scope`), then green.
- [x] `MeetingDigestService.digest` computes utterances from `segments` and
      chunks `utterances.map(\.asSegment)`; `validIDs` unchanged (still keyed
      off `segments`).
- [x] Failing service-level test written first
      (`test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged`)
      — confirmed red (3 prompts vs. 2 unmerged chunks), then green (1 prompt
      vs. 2 unmerged chunks), and an action citing the first constituent's
      persistent id survives evidence validation.
- [x] All pre-existing `MeetingDigestServiceTests` still pass unmodified.
- [x] `swift test` (beta toolchain) — full suite green.
- [x] `swift build` (beta toolchain) — exit 0.
- [x] No files touched outside the permitted set.
- [x] No push, no PR — stopped after local commits for orchestrator review.
