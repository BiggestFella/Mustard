# Fresh-context review — BAK-249 (11dc11e..HEAD on agent/bak-249-blockkind)

Reviewer: fresh-context sonnet subagent (no prior involvement), 2026-07-12.

- **Standards: PASS** — pure Logic/ addition, zero real deletions in
  NoteDecoration.swift, matches file style, no unrelated refactors.
- **Spec: PASS** — all Phase 0 acceptance criteria met; round-trip clause
  legitimately deferred to Phases 2/3 (no rewrite API exists in Phase 0);
  no premature consumers (grep: blockKind/BlockKind only in the two Logic
  files + tests; SlashMenu/MarkdownTextView/BlockReorder untouched).
- **Risk: PASS** — touched paths ⇒ medium, matches declared `risk:medium`;
  zero high-risk substrings in diff; no outward actions.
- **Test: PASS** — reviewer independently ran checks:
  `Build complete! (0.26s)`;
  `Executed 717 tests, with 1 test skipped and 0 failures` (696 + 21, the
  1 skip is the pre-existing env-gated SnapshotRenderTests). Coverage judged
  thorough (per-kind fixtures + edge cases, public-interface-only asserts).
  Traced isTableSeparatorRow on odd inputs (`|-|`, `---`, `:|:`, lone `|`) —
  no consequential misclassification; bounds-guard mirrors the pre-existing
  spans(_:in:) pattern.

## Findings

1. **NON-BLOCKING** — heading(Int) unclamped 1-6 diverges from the spec's
   literal `// 1...4` inline comment (not its intent; h5/h6 already render).
   Surface to Leon for a one-line confirmation; no code action to merge.
2. **NON-BLOCKING** — tests+impl landed as one squashed commit, so test-first
   ordering isn't provable from history. Process nit.

## Verdict: APPROVE
