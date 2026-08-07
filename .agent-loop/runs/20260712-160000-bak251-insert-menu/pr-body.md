## BAK-251 — Phase 2: expanded insert (/) menu (epic BAK-248)

Grows the slash menu from 5 flat commands to **16 grouped commands** matching the
Craft/Tolaria reference: **Headings** (H1-H4) · **Basic blocks** (Quote, Bullet
List, Numbered List, Check List, Paragraph, Code Block, Divider) · **Advanced**
(Table, Link to note, Sub-page, Ask the agent) · **Media** (Image, syntax-only
`![]()` with the caret landing in the url slot).

Explicitly excluded per spec scope: Video/Audio/File/Mermaid, inline image
preview.

### How

- `Logic/SlashMenu.swift`: Kind/Group enums, insertion templates; filtering keeps
  the existing word-prefix shape over one flat array, so `MarkdownTextView`'s
  keyboard interception needed **zero changes** (verified generic + clamped).
- `Views/SlashMenuView.swift`: quiet-caps group headers, 360pt height cap with
  auto-scroll keeping the keyboard highlight visible (review fix).
- Table renders as plain text (inline spans still work inside cells) — full table
  layout deliberately out of scope; `BlockKind` already classifies it from
  Phase 0.
- Round-trip guard extended: every new insertion template parses back unaltered
  (table/divider/image/code-fence + headings/quote/lists).

### Verification

- `swift test`: **747 tests, 1 skipped (pre-existing env-gated), 0 failures**
  (baseline 728; SlashMenuTests 14→33).
- `swift build` + `./build-app.sh`: clean.
- ⚠ **Leon eye-check pending:** grouped menu look, ↑/↓ traversal + auto-scroll,
  new insertions (table template, image url-slot caret).

### Review

Fresh-context review: **APPROVE-WITH-FOLLOW-UPS, 0 blocking.** Reviewer compared
the rewritten SlashMenuTests test-by-test against the old file — strengthening
only, byte-exact templates for all original commands. Sole finding (highlight
scrolls off-screen) fixed inline (`a04f7eb`). Report:
`.agent-loop/runs/20260712-160000-bak251-insert-menu/review-report.md`.

Risk class: **medium** → auto-merge on green per `.agent-loop/risk.yml`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
