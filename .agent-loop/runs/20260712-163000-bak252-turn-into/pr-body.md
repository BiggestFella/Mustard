## BAK-252 — Phase 3: "Turn into" + block actions context menu (epic BAK-248)

Right-click the block gutter's ⠿ handle to get **Turn into** (Paragraph,
Heading 1-4, Quote, Bullet/Numbered/Check List, Code Block) and **Actions**
(Duplicate, Delete, Move up/down — disabled at document edges). Dividers hide
"Turn into" (nothing to convert). Frontmatter blocks get no menu.

### How

- **Pure `Logic/BlockTransform.swift`** (51 tests): content-preserving
  conversions (prefix strip/add per line, code-fence wrap/unwrap), lossy
  plain-text fallback for table/image/subpage, byte-pinned splices for
  duplicate/delete reusing `BlockReorder`. Every action returns the caller's
  next selection; `nil` for frontmatter/out-of-bounds.
- **Round-trip enforced adversarially:** transforms guarantee the output block
  reclassifies as the TARGET kind — content that would misclassify (e.g.
  `# > note` → Paragraph leaving a quote-shaped line) gets standard markdown
  backslash escapes (`\>`, `\#`, `\-`, `1\.`, `` \``` ``), reusing
  `NoteDecoration.classify` (one shared line classifier, no duplicated rules).
- **View wiring:** context menu dispatches through the same undo-safe
  whole-document splice `moveBlock` uses (`applyWholeDocumentSplice`, refactored
  out behavior-preserving), so undo works and Phase 1's marker-visibility
  recompute fires; `MarkdownBlockRect` now carries `BlockKind` for menu gating.

### Review cycle (the process worked)

Fresh-context review returned **REQUEST-CHANGES**: a confirmed classifier-echo
bug (turn-into → Paragraph could silently produce a quote/bullet block) that the
bland `"hello"` matrix fixture couldn't catch. Fixed on-branch with TDD
regressions (both reviewer repros pinned verbatim); the prescribed audit found
and fixed a **second instance** (table-cell ``` closing a code fence early).
Divider menu gating (previously claimed in a comment but unimplemented) and the
missing frontmatter-adjacent tests were also fixed. Full report:
`.agent-loop/runs/20260712-163000-bak252-turn-into/review-report.md`.

### Verification

- `swift test`: **798 tests, 1 skipped (pre-existing env-gated), 0 failures**
  (747 baseline → 790 impl → 798 post-fix; BlockTransformTests 51/51).
- `swift build` + `./build-app.sh`: clean.
- Reviewer independently traced the gutter→coordinator index mapping (the
  corrupt-the-wrong-block failure mode): consistent across all four sites.
- ⚠ **Leon eye-check pending:** menu feel, one-step undo per action, caret
  placement, escaped output readability.

Risk class: **medium** → auto-merge on green per `.agent-loop/risk.yml`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
