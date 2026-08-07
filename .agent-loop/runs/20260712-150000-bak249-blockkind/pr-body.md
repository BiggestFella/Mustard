## BAK-249 — Phase 0: shared BlockKind model (epic BAK-248)

First slice of the Craft editor menus epic (spec:
`docs/specs/2026-07-12-craft-editor-menus-design.md`, included in this PR along
with the F23 build-order entry).

### What

- New canonical `BlockKind` enum (`Sources/MustardKit/Logic/BlockKind.swift`):
  paragraph, heading(Int), quote, bulletList/numberedList/todoList, codeBlock,
  divider, table, image, subpage.
- Additive `NoteDecoration.blockKind(_:of:)` classifier (+105 lines, zero
  deletions) — the single source of block-type truth the expanded insert menu
  (BAK-251) and "turn into" transform (BAK-252) will consume.
- New grammar classification for table (pipe rows + separator row), image
  (bare `![alt](url)` line), and todo-vs-bullet split. Classification only —
  no rendering/decoration change, no rewrite API, markdown stays truth.
- Frontmatter deliberately has no `BlockKind` case (`blockKind` returns `nil`);
  heading levels 5-6 pass through unclamped (spec's "1...4" is the Phase-2
  insert-menu range — rationale documented in `BlockKind.swift`).

### Verification

- `swift test`: **717 tests, 1 skipped (pre-existing env-gated snapshot), 0
  failures** (baseline before change: 696) — run by builder, orchestrator, and
  fresh-context reviewer independently.
- `swift build`: `Build complete!`
- 21 new `BlockKindTests` (per-kind fixtures + edge cases), all existing tests
  pass unmodified.

### Review

Fresh-context review (standards / spec / risk / test): **APPROVE**, 0 blocking
findings. Non-blocking notes recorded in
`.agent-loop/runs/20260712-150000-bak249-blockkind/review-report.md`.

Risk class: **medium** (`Sources/`+`Tests/`+`docs/` only; no high-risk paths,
no outward actions) → auto-merge on green per `.agent-loop/risk.yml`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
