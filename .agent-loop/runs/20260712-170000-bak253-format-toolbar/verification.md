# Verification — BAK-253 (agent/bak-253-format-toolbar @ 1fadde6)

## Required checks (`.agent-loop/checks.yml`)

- **test:** `swift test` →
  `Executed 835 tests, with 1 test skipped and 0 failures (0 unexpected)`
  (baseline 798 + 6 NoteDecorationTests (strikethrough/highlight spans) + 31
  InlineFormatTests; the 1 skip is the pre-existing env-gated
  SnapshotRenderTests). Run independently by builder, orchestrator, reviewer.
- **build:** `swift build` → `Build complete! (0.28s)`
- **app assembly:** `./build-app.sh` → build/Mustard.app assembled (builder run)
- **lint:** no linter configured — skipped per checks.yml no-op

## Diff shape (b219223..1fadde6, three commits)

- `Logic/InlineFormat.swift` (new, 226) — pure toggle API with re-parse guard
- `Logic/NoteDecoration.swift` (+40) — .strikethrough/.highlight span kinds
- `Logic/Theme.swift` (+5) — highlightBg/strikethrough tokens
- `Views/InlineFormatBarView.swift` (new, 50), `MarkdownTextView.swift` (+87),
  `NoteEditorView.swift` (+25) — floating toolbar, selection-anchored
- Tests: InlineFormatTests (new, 31), NoteDecorationTests (+6)

## Reviewer-verified claims (cold context)

- Re-parse wrap guard is real code with a clean nil failure path (no partial
  writes); involution tested for all six kinds.
- Link toggle reads the live selection at click time (no stale-range risk).
- Toolbar/slash-menu overlap structurally impossible (disjoint selection-length
  guards).
- `~~~` does not collide with fences (fences are ``` -only here; regex verified
  empirically not to match).
- applyWholeDocumentSplice reuse safe (scroll save/restore + selection clamp
  pre-existing).

## Pending

⚠ **Leon eye-check:** toolbar position/feel (anchored ~40pt above selection
start), each toggle incl. link url-slot, strikethrough/highlight rendering,
one-step undo. Follow-ups (== prose false-positive, per-selection-change scan
cost, unwrap test completeness) appended to BAK-254.
