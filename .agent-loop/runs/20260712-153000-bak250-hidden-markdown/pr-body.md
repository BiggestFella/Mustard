## BAK-250 — Phase 1: fully-hidden markdown, Craft-style focus reveal (epic BAK-248)

Markdown syntax markers (heading `#` prefixes, blockquote `>`, `**`/`*` emphasis
delimiters, inline-code backticks) now **fully hide** when the cursor isn't in
that block and reveal (existing dimmed styling, unchanged) when it is. An
unfocused document reads like rendered rich text; the `.md` on disk stays
byte-identical truth.

### How

- **Pure decision layer** (`NoteDecoration.markerVisibility/revealedBlocks/
  hideableMarkerRanges`, TDD, 11 new tests): given source + focused range, which
  marker ranges hide vs reveal. Block-granularity reveal; multi-block selections
  reveal every touched block; `nil` focus hides everything.
- **Presentation-only hiding** via TextKit-1 `setNotShownAttribute` glyph flags —
  never a text-storage edit, so copy/paste/Save see full markdown and revealed
  layout metrics are untouched. Full recompute on load/doc-replace/topology
  changes; cheap block-diff on pure caret moves; fast-path reveal of the edited
  block on every keystroke so typed syntax shows instantly.
- **Deliberately still visible** (documented in code): bullet/ordered prefixes,
  fence delimiters, rule lines, wikilink brackets (own pill/card surface),
  checkbox brackets (no distinct span exists yet — see BAK-254).

### Verification

- `swift test`: **728 tests, 1 skipped (pre-existing env-gated), 0 failures**
  (baseline 717) — run independently by builder, orchestrator, and reviewer.
- `swift build` + `./build-app.sh`: clean, app assembles.
- ⚠ **Leon eye-check pending** (views are build+eye): hide/reveal feel, caret
  stability crossing blocks, cmd-tab-away behavior (BAK-254 note), wikilink
  pills/subpage cards/slash menu/drag-reorder unaffected.

### Review

Fresh-context review: **APPROVE-WITH-FOLLOW-UPS, 0 blocking.** Finding 1
(stale-baseline guard) fixed inline (`b896a58`); findings 2-3 (caret-move perf
on large notes, checkbox-bracket hiding later) filed as **BAK-254**. Full report:
`.agent-loop/runs/20260712-153000-bak250-hidden-markdown/review-report.md`.

Risk class: **medium** (Logic/Views/Tests only; no high-risk paths; no outward
actions) → auto-merge on green per `.agent-loop/risk.yml`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
