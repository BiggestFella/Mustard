## Craft editor — make marker-hiding actually work + render block glyphs

Follow-up to epic BAK-248, fixing what Leon's eye-check surfaced and shipping the
BAK-254 checkbox item.

### 1. Marker hiding rewritten (the eye-check bug)
The Phase-1 hiding was built on `NSLayoutManager.setNotShownAttribute`, which
**never actually hid anything in the running app**: a "not shown" glyph keeps its
advance width (no reflow) and the flag is wiped every time `applyDecorations`
regenerates glyphs. Replaced with the `shouldGenerateGlyphs` `.null` glyph
property — null glyphs draw nothing *and* take zero width (true reflow), and are
applied at generation time so regeneration re-applies them. Focus now tracked via
`FocusReportingTextView` (real first-responder changes, not keystroke-timed
editing notifications). Policy per Leon: **always hidden**, even on the focused
line (Craft/Typora model) — which also drops the per-caret-move rescan.

### 2. Block glyphs
`- [ ]`/`- [x]` → a **clickable checkbox** that toggles the markdown; `- `/`* ` →
a bullet; `---` → a divider rule. Drawn over the transparent raw-markdown
characters via a `.mustardBlockGlyph` attribute + `CardLayoutManager` (same
pattern as subpage cards) — **text == source preserved, no NSTextAttachment**.
Numbered lists keep their `1.`; blockquotes unchanged for now.

### Pure logic (TDD)
`NoteDecoration.blockGlyph` (classify + marker range) and `CheckboxToggle.toggled`
(length-preserving `[ ]`↔`[x]`), 26 new tests.

### Verification
- `swift test`: **866 tests, 1 skipped, 0 failures** (baseline 840).
- `swift build` + `./build-app.sh`: clean. Leon eye-confirmed rendering + click.
- Fresh-context review: **APPROVE, 0 blocking.** One non-blocking finding
  (below-last-line false toggle) fixed inline with a fragment-rect guard +
  modifier-click exclusion; remaining perf/UX notes on BAK-254.

Risk: **medium** (Logic/Views/Tests only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
