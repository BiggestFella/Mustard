# Verification — BAK-252 (agent/bak-252-turn-into @ dc09b45)

## Required checks (`.agent-loop/checks.yml`) — final post-fix run (orchestrator)

- **test:** `swift test` →
  `Executed 798 tests, with 1 test skipped and 0 failures (0 unexpected)`
  (baseline 747 → 790 after implementation (+43 BlockTransformTests) → 798
  after review fixes (+8); the 1 skip is the pre-existing env-gated
  SnapshotRenderTests). `swift test --filter BlockTransformTests` → 51/51.
- **build:** `swift build` → `Build complete! (0.24s)`
- **app assembly:** `./build-app.sh` → build/Mustard.app assembled (builder run)
- **lint:** no linter configured — skipped per checks.yml no-op

## Diff shape (418f88d..dc09b45, four commits)

- `Sources/MustardKit/Logic/BlockTransform.swift` (new, ~496 lines final) —
  turnInto/duplicate/delete/moveUp/moveDown + misclassification escapes
- `Sources/MustardKit/Logic/BlockReorder.swift` (+7/-1) — splitTrailingBlanks
  access widening (reuse, not duplication)
- `Sources/MustardKit/Logic/NoteDecoration.swift` — classify/LineKind access
  widening (review fix; one shared line classifier)
- `Sources/MustardKit/Views/{BlockGutterOverlay,MarkdownTextView,NoteEditorView}.swift`
  — context menu, MarkdownBlockRect.kind, applyWholeDocumentSplice, proxy wiring
- `Tests/MustardTests/BlockTransformTests.swift` (new, 51 tests incl.
  adversarial round-trip matrix + reviewer-repro regressions)

## Review cycle

Fresh-context review returned REQUEST-CHANGES (classifier-echo blocking bug) →
fixed on-branch (`6d83a83`, `dc09b45`) with TDD regressions → orchestrator
re-verified (repro test present at BlockTransformTests.swift:311, full suite +
build green). Details: review-report.md.

## Pending

⚠ **Leon eye-check:** context menu on the ⠿ handle (Turn into submenu +
Actions), divider hides Turn into, caret lands sensibly after each action,
undo reverses each action in one step, escaped output (`\>` etc.) reads
acceptably when a conversion needed escaping.
