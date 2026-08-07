## BAK-253 — Phase 4: inline formatting toolbar (epic BAK-248, final phase)

Select text and a floating toolbar appears with six toggles: **Bold** ·
*Italic* · ~~Strikethrough~~ · `Inline code` · ==Highlight== · Link. Each wraps
or unwraps the selection's markdown (`**`, `*`, `~~`, `` ` ``, `==`,
`[text](url)` with the caret landing in the url slot). Color is excluded per
the epic's scope decisions.

### How

- **New inline span kinds** `.strikethrough`/`.highlight` in `NoteDecoration`
  (same claimed-mask pattern as bold/italic; Phase 1 marker hiding works on
  them for free; Theme tokens for rendering, no fresh hex).
- **Pure `Logic/InlineFormat.swift`** (31 tests): toggle with a re-parse guard —
  a wrap is only returned if re-parsing yields the expected span at the
  expected range, so cross-block selections, nesting conflicts, and scan-order
  collisions become clean no-ops, never partial writes. Involution tested for
  all six kinds (toggle twice = byte-identical). Conservative policy: empty /
  multi-block / partial-overlap selections are no-ops.
- **Toolbar** mounts like the slash-menu overlay, anchored above the selection;
  structurally can't fight the slash menu (disjoint selection-length guards).
  Dispatches through the same undo-safe splice channel as Phase 3 (one undo
  step, marker-visibility recompute included).

### Verification

- `swift test`: **835 tests, 1 skipped (pre-existing env-gated), 0 failures**
  (baseline 798 + 37) — run independently by builder, orchestrator, reviewer.
- `swift build` + `./build-app.sh`: clean.
- ⚠ **Leon eye-check pending:** toolbar position/feel, each toggle (esp. link
  url-slot), strikethrough/highlight rendering, one-step undo.

### Review

Fresh-context review: **APPROVE-WITH-FOLLOW-UPS, 0 blocking.** Non-blocking
findings (a reproducible `==` false-positive on technical prose, a second
per-selection-change O(doc) scan, unwrap-test completeness) appended to
**BAK-254** with fix directions. Report:
`.agent-loop/runs/20260712-170000-bak253-format-toolbar/review-report.md`.

Risk class: **medium** → merge on green per `.agent-loop/risk.yml`.

Closes the build phases of epic **BAK-248** (Phases 0-4 all merged).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
