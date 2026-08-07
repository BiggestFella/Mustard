# Run 20260712-160000-bak251-insert-menu

- **Issue:** BAK-251 — Phase 2 — expanded insert (`/`) menu (epic BAK-248)
- **Spec:** docs/specs/2026-07-12-craft-editor-menus-design.md (Phase 2 row)
- **Branch:** agent/bak-251-insert-menu off origin/main (92c61df; includes merged
  BlockKind foundation + hidden-markdown Phase 1)
- **Risk (declared):** medium — `risk:medium`; expected paths
  `Sources/MustardKit/Logic/{SlashMenu,NoteDecoration}.swift`,
  `Sources/MustardKit/Views/SlashMenuView.swift` (+ small MarkdownTextView
  touches if insertion wiring needs them), `Tests/`.

## Objective

Grow the slash menu from 5 flat commands to the full block-type list, driven by
`BlockKind`: Heading 1-4, Quote, Bullet List, Numbered List, Check (To-do) List,
Paragraph, Code Block, Divider, Table, Image (syntax-only `![]()` insert — no
thumbnail), plus the existing Link to note, Sub-page, Ask the agent.

## Acceptance criteria

1. `SlashMenu` command list + filtering stays pure/TDD'd (extends `SlashMenuTests`);
   filtering mirrors the existing word-prefix shape. Commands grouped for display
   (Headings / Basic blocks / Advanced / Media-syntax) like the reference shot.
2. Table and Divider get whatever *decoration* support insertion needs so an
   inserted block renders sanely (divider already has a `rule` block kind; table
   needs at least neutral monospaced-ish rendering — NOT full table layout, that
   is out of scope).
3. Insertions write plain markdown at the trigger point (same `insertion` pattern
   as today); every new insertion template round-trips (`parse(render) == source`
   guard extended for table/divider/image templates).
4. Video/Audio/File/Mermaid explicitly excluded (spec scope decision 3).
5. `SlashMenuView` renders groups + keeps keyboard navigation (↑/↓/⏎/Esc) working.
6. Existing tests pass unmodified; `swift test` + `swift build` green.
