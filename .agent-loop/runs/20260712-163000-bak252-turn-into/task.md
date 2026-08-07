# Run 20260712-163000-bak252-turn-into

- **Issue:** BAK-252 — Phase 3 — "turn into" + block actions context menu
  (epic BAK-248)
- **Spec:** docs/specs/2026-07-12-craft-editor-menus-design.md (Phase 3 row +
  "Failure / edge behaviour": lossy conversions never corrupt the file)
- **Branch:** agent/bak-252-turn-into off origin/main (418f88d; includes merged
  Phases 0-2)
- **Risk (declared):** medium — `risk:medium`; expected paths
  `Sources/MustardKit/Logic/` (new BlockTransform + possibly BlockReorder
  extension), `Sources/MustardKit/Views/{BlockGutterOverlay,MarkdownTextView}.swift`,
  `Tests/`.

## Objective

Right-click / block-handle context menu with:

- **Turn into:** convert the current block's markdown to any other convertible
  `BlockKind` (paragraph, heading 1-4, quote, bullet/numbered/todo list, code
  block). New pure transform, e.g. `Logic/BlockTransform.swift`.
- **Actions:** Duplicate, Delete, Move up, Move down — reusing/extending
  `BlockReorder`'s splice approach.

## Acceptance criteria

1. Pure `BlockTransform` logic, TDD'd: `turnInto(source, block, target) -> (newSource, selection)`
   style API. Content-preserving where types are structurally compatible
   (heading↔paragraph↔quote; list-type↔list-type per line; paragraph→list;
   code block wraps/unwraps fences). Lossy conversions fall back to the block's
   plain-text content — never malformed markdown on disk ("never corrupt the
   file, not never lose formatting").
2. Non-convertible targets for a given source (e.g. table→heading keeps only
   plain text; divider has no content) are either handled by the plain-text
   fallback or excluded from the menu — decide, document, test.
3. Duplicate/Delete/Move up/Move down as pure splice functions (extend
   `BlockReorder` or the new unit), byte-pinned tests like BlockReorderTests.
4. Round-trip guard extended: every transform output parses back to the target
   BlockKind (or documented fallback) without alteration.
5. Context menu UI on the existing block gutter handle (and/or right-click in
   the text view) — renders + dispatches only; keyboard/mouse paths through the
   one undo-safe splice mechanism `performSlashCommand`/`moveBlock` already use.
6. Existing tests pass unmodified; `swift test` + `swift build` green.
