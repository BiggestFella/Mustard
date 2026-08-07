# Run 20260712-153000-bak250-hidden-markdown

- **Issue:** BAK-250 — Phase 1 — fully-hidden markdown (Craft-style focus reveal)
  (epic BAK-248)
- **Spec:** docs/specs/2026-07-12-craft-editor-menus-design.md (Phase 1 row +
  "Failure / edge behaviour")
- **Branch:** agent/bak-250-hidden-markdown off origin/main (b683c5a, includes
  merged BAK-249 BlockKind foundation)
- **Risk (declared):** medium — `risk:medium`; expected paths
  `Sources/MustardKit/Logic/NoteDecoration.swift`,
  `Sources/MustardKit/Views/MarkdownTextView.swift`, `Tests/` (Sources/ ⇒ medium;
  no high-risk substring). Flagged in the epic as the highest *technical* risk
  (NSTextView), not policy risk.

## Objective

Markdown syntax markers (`##`, `**`, `*`, `` ` ``, `- [ ]`/`- [x]` brackets, `>`)
currently render dimmed but visible everywhere. Change to Craft behavior: markers
are **fully hidden** when the cursor/selection is NOT in that block/line, and
**revealed** (current dimmed style) when it is.

## Acceptance criteria

1. Pure, focus-aware decoration decision in `Logic/` (TDD): given source + the
   focused range, which marker ranges are hidden vs revealed. Existing
   `NoteDecoration` span output stays byte-identical for the focused block
   (revealed = today's dimmed rendering).
2. `MarkdownTextView` applies hide/reveal on selection change; selection anchors
   stay stable across the transition (range-based reveal, spec "Failure / edge
   behaviour").
3. Round-trip guarantee untouched: hiding is presentation-only; the underlying
   text (and file on disk) is never modified. No rewrite API.
4. Wikilink pills, subpage cards, checkbox rendering keep working.
5. Range-scoped + debounced enough that typing is never blocked (spec edge rule);
   pathological-note fallback path unchanged.
6. `swift test` + `swift build` green; existing tests pass (mechanical updates to
   decoration tests allowed ONLY if the span model gains a hidden/revealed
   dimension — assertions may extend, not weaken).
