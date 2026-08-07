# Verification — BAK-251 (agent/bak-251-insert-menu @ a04f7eb)

## Required checks (`.agent-loop/checks.yml`) — final run post-review-fix

- **test:** `swift test` →
  `Executed 747 tests, with 1 test skipped and 0 failures (0 unexpected)`
  (baseline 728 + 19 net-new SlashMenuTests; 33 total in that suite; the 1 skip
  is the pre-existing env-gated SnapshotRenderTests)
- **build:** `swift build` → `Build complete!`
- **app assembly:** `./build-app.sh` → build/Mustard.app assembled (builder run)
- **lint:** no linter configured — skipped per checks.yml no-op

## Diff shape (92c61df..a04f7eb)

- `Sources/MustardKit/Logic/SlashMenu.swift` (+123) — 16 grouped commands,
  Kind/Group enums, insertion templates
- `Sources/MustardKit/Views/SlashMenuView.swift` (+56/-9 across two commits) —
  grouped section headers, scroll/height cap, review-fix auto-scroll
- `Tests/MustardTests/SlashMenuTests.swift` (+187/-38) — 33 tests

## Review-driven change

`a04f7eb` — ScrollViewReader auto-scroll keeps the keyboard highlight visible
past the 360pt fold (review finding, fixed inline).

## Reviewer-verified claims (cold context)

- Test rewrite is a strengthening, not weakening: original 5 commands' templates
  byte-identical (checkList kept `- [ ] `/caret 6; old flat Heading preserved
  exactly as heading(2)); filter tests byte-identical where behavior unchanged.
- Keyboard index math in MarkdownTextView unchanged and safe for 16 items
  (min/max clamps, no ≤5 assumption); caret-offset convention honored for the
  mid-template codeBlock/image carets.
- Round-trip guard extended beyond the criterion (table/divider/image/codeBlock
  + headings/quote/lists).
- Table decoration deliberately NOT added: pipe tables render as plain text with
  working inline spans — acceptable per task.md's own escape hatch.

## Pending

⚠ **Leon eye-check:** grouped menu look, keyboard traversal + auto-scroll feel,
each new insertion (esp. table template and image url-slot caret).
