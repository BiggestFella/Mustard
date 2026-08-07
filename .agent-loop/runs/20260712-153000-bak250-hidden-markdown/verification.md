# Verification — BAK-250 (agent/bak-250-hidden-markdown @ b896a58)

## Required checks (`.agent-loop/checks.yml`)

Run three times independently (builder, orchestrator post-vet, orchestrator
post-guard-fix); final run by orchestrator after the inline review fix:

- **test:** `swift test` →
  `Executed 728 tests, with 1 test skipped and 0 failures (0 unexpected)`
  (baseline 717 + 11 new focus-aware NoteDecorationTests; the 1 skip is the
  pre-existing env-gated SnapshotRenderTests)
- **build:** `swift build` → `Build complete! (0.27s)`
- **app assembly:** `./build-app.sh` → build/Mustard.app assembled (builder run)
- **lint:** no linter configured — skipped per checks.yml no-op

## Diff shape (b683c5a..b896a58)

- `Sources/MustardKit/Logic/NoteDecoration.swift` (+146) — pure
  `markerVisibility(_:focusedRange:)` / `revealedBlocks` / `hideableMarkerRanges`
- `Sources/MustardKit/Views/MarkdownTextView.swift` (+140/-6 across two commits) —
  TextKit-1 `setNotShownAttribute` glyph flags; focus tracking; full-vs-incremental
  recompute split; selection-change guard hardened post-review
- `Tests/MustardTests/NoteDecorationTests.swift` (+152, 11 tests)

## Review-driven change

`b896a58` — `textViewDidChangeSelection` now also guards `isProgrammaticUpdate`
(fresh-context review finding 1, fixed inline; findings 2-3 filed as BAK-254).

## Pending

⚠ **Leon eye-check** (views are build+eye per CLAUDE.md): markers hide when
cursor leaves a block and reveal on entry; caret doesn't jump crossing
hide/reveal; cmd-tab-away behavior (see BAK-254 note); wikilink pills, subpage
cards, slash menu, drag-reorder unaffected.
