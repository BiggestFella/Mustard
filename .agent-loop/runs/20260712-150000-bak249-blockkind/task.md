# Run 20260712-150000-bak249-blockkind

- **Issue:** BAK-249 — Phase 0 — shared BlockKind model (epic BAK-248)
- **Spec:** docs/specs/2026-07-12-craft-editor-menus-design.md
- **Branch:** agent/bak-249-blockkind (off claude/editor-craft-redesign-plan-02c2f0,
  which carries the spec commit cc159b3; PR targets main)
- **Risk (declared):** medium — label `risk:medium`; touched paths expected to be
  `Sources/MustardKit/Logic/NoteDecoration.swift` + `Tests/` (Sources/ ⇒ medium,
  Tests/ ⇒ low; no high-risk path). Auto-merge on green CI + passing review.

## Objective

Extract a canonical `BlockKind` enum (paragraph, heading 1-4, quote, bullet /
numbered / todo list, code block, divider, table, image, subpage) from
`NoteDecoration`'s existing block partitioner. Pure refactor + foundation — no
user-visible behavior change. Insert menu (Phase 2/BAK-251), turn-into transform
(Phase 3/BAK-252), and the round-trip test will all consume this one enum.

## Acceptance criteria (from issue + spec)

1. One public `BlockKind` enum in `Sources/MustardKit/Logic/` with the cases above.
2. `NoteDecoration`'s partitioner classifies every block as a `BlockKind`
   (existing private notions consolidated, not duplicated).
3. TDD: classification tests written first, fixtures per kind, extending
   `NoteDecorationTests` conventions.
4. No behavior change: existing `NoteDecorationTests` / `SlashMenuTests` /
   `BlockReorderTests` pass unmodified (except mechanical renames if any).
5. `swift test` and `swift build` green.
