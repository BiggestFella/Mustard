# Run 20260712-170000-bak253-format-toolbar

- **Issue:** BAK-253 — Phase 4 — inline formatting toolbar (Decorations)
  (epic BAK-248, final phase)
- **Spec:** docs/specs/2026-07-12-craft-editor-menus-design.md (Phase 4 row)
- **Branch:** agent/bak-253-format-toolbar off origin/main (b219223; includes
  merged Phases 0-3)
- **Risk (declared):** medium — `risk:medium`; expected paths
  `Sources/MustardKit/Logic/` (new InlineFormat), `Sources/MustardKit/Views/`
  (new toolbar view + MarkdownTextView/NoteEditorView wiring), `Tests/`.

## Objective

Floating toolbar on text selection: Bold, Italic, Strikethrough, Inline code,
Highlight, Link — each wraps/unwraps the selection with its markdown syntax
(`**`, `*`, `~~`, `` ` ``, `==`, `[](url)`), toggling off when the selection is
already formatted. Color explicitly excluded (spec scope decision 3).

## Acceptance criteria

1. Pure `Logic/InlineFormat.swift`, TDD'd: `toggle(source, selection, format)
   -> (newSource, newSelection)` style API. Toggle-ON wraps; toggle-OFF detects
   the selection is already wrapped (delimiters inside or immediately around
   the selection) and unwraps. Reuse `NoteDecoration`'s inline-span detection
   for "is already formatted" — do not duplicate the span grammar.
2. Edge cases TDD'd: partial-overlap selection (selection half-in a bold span),
   nested formats (bold inside italic), selection spanning a block boundary
   (define: clamp to block or no-op — document), empty selection (no-op or
   caret-word — document), delimiters-in-selection, strikethrough/highlight
   spans that NoteDecoration may not yet style (add spans if missing — check
   first; `~~`/`==` may need new inline span kinds + decoration + hide support
   consistent with Phase 1).
3. Selection after toggle keeps the same TEXT selected (range shifts by
   delimiter length, never selects the delimiters).
4. Toolbar view: appears near the selection on selection of length > 0 (mirror
   the slash-menu anchoring pattern), Theme tokens, renders + dispatches only,
   through the undo-safe splice path (this is a RANGE splice, not whole-doc —
   reuse the channel `performSlashCommand` uses, or the whole-doc helper if
   range splice isn't available — document the choice + undo behavior).
5. Round-trip: toggled output parses back with the expected inline spans;
   toggle-then-toggle returns the byte-identical original (involution test).
6. Existing tests pass unmodified; `swift test` + `swift build` green.
   Baseline: 798 pass / 1 skip.
