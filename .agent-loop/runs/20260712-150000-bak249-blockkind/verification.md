# Verification — BAK-249 (agent/bak-249-blockkind @ 744ebd8)

## Required checks (`.agent-loop/checks.yml`) — run by orchestrator, 2026-07-12

- **test:** `swift test` →
  `Executed 717 tests, with 1 test skipped and 0 failures (0 unexpected) in 3.259s`
  (baseline before change: 696 tests, 1 skipped, 0 failures — 21 new BlockKindTests)
- **build:** `swift build` → `Build complete! (0.26s)`
- **lint:** no linter configured for Mustard — skipped (per checks.yml no-op)

## Builder evidence (sonnet subagent, vetted by orchestrator)

- Baseline run BEFORE changes: 696 tests, 0 failures (no pre-existing breakage).
- `swift test --filter BlockKindTests` → 21/21 passed.
- `swift test --filter NoteDecorationTests` → 35/35 passed, **unmodified**.
- Orchestrator re-read the full diff (`git show 744ebd8`): additions only
  (+317 lines, 3 files), no existing code changed, Views/ untouched.

## Diff shape

- `Sources/MustardKit/Logic/BlockKind.swift` (new, 32 lines)
- `Sources/MustardKit/Logic/NoteDecoration.swift` (+105, additive
  `blockKind(_:of:)` + private helpers, inserted before `// MARK: - Spans`)
- `Tests/MustardTests/BlockKindTests.swift` (new, 180 lines, 21 tests)

## Notable decisions (documented in code)

- Frontmatter: not a `BlockKind` case; `blockKind` returns `nil` for it.
- Heading levels 5-6: pass through unclamped (spec's "1...4" is the Phase-2
  insert-menu range, not a classification constraint).
- Table/image/subpage classification applies within `.text` blocks only —
  matches existing partitioner behavior, no partitioner change needed.
