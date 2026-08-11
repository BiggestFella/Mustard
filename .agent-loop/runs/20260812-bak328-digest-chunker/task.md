# BAK-328: digest chunker sizes chunks by rendered-prompt cost, not raw text

## Issue summary

`MeetingDigestChunker.chunks` sized chunks using `tokenCount(segment.text)` —
the raw transcript text only. But `MeetingDigestService.chunkPrompt` renders
each segment as `[<persistentID>] (<channel> <start>–<end>s): <text>`, a
~44-char id/timing prefix the chunker never accounted for. Real-world
segments average ~15 chars of text, so rendered prompts ran ~3.4x the
enforced budget — the first chunk overflowed the 4096-token on-device model
context (`.model(.contextOverflow)`) past ~5 minutes of speech. Short
meetings fit and succeeded, masking the bug; it is purely an accounting
error, not a capability gap.

Separately, `MeetingDigestService.digest` set
`budget = max(256, capabilities.contextSize / 2)` — a flat guess that
ignored the actual size of the loaded instructions and left no accounted
headroom for the structured output.

## Design decisions (given, followed as specified)

1. **Single source of truth for the rendered line.** Added
   `MeetingDigestChunker.renderedLine(for:)` — a pure static function
   producing exactly the line `chunkPrompt` builds. `chunkPrompt` now calls
   it instead of duplicating the rendering inline. The chunker costs each
   segment as `tokenCount(renderedLine(for: segment))`; the `tokenCount`
   closure's contract (plain string → token estimate) is unchanged.
2. **Real budget.** `digest`'s budget is now
   `max(256, capabilities.contextSize - tokenCount(instructions) - outputReserve)`,
   with `MeetingDigestService.outputReserve = 1024` (headroom for the
   guided-generation output and the chunk prompt's date preamble). The
   reduction pass is untouched.
3. Silence-boundary preference and oversized-single-segment handling are
   unchanged in behavior (cut *positions* may legitimately shift because
   costs changed).

## Acceptance criteria checklist

- [x] `MeetingDigestChunker.renderedLine(for:)` added, pure, matches
      `chunkPrompt`'s exact rendering (id, channel, `%.1f–%.1fs` timing).
- [x] `chunkPrompt` calls `renderedLine`; duplicated inline rendering
      deleted.
- [x] `chunks` costs each segment via `tokenCount(renderedLine(for:))`,
      including the post-silence-cut token recount.
- [x] `MeetingDigestService.digest` budget = real context minus
      instructions minus a documented output reserve (1024).
- [x] Failing test written first for the rendered-cost regression
      (~1,100-segment fixture); confirmed red, then green.
- [x] Failing test written first for the budget formula; confirmed red,
      then green.
- [x] Existing chunker tests (silence-boundary cut, no-silence cut,
      oversized-segment) updated to derive their budgets from the real
      `renderedLine` cost instead of stale raw-text character counts;
      behavior/invariants preserved.
- [x] `swift test` — full suite green.
- [x] `swift build` — exit 0.
- [x] No files touched outside the permitted set.
- [x] No push, no PR — stopped after local commits for orchestrator review.
