# Fresh-context review — BAK-252 (418f88d..HEAD on agent/bak-252-turn-into)

Reviewer: fresh-context sonnet subagent, 2026-07-12.
Initial verdict: **REQUEST-CHANGES** (one blocking bug) → blocking finding
fixed on-branch, verified by orchestrator → cleared to merge.

- **Standards: PASS** — pure logic in Logic/, views render/dispatch;
  BlockReorder reused not reimplemented; style matches conventions.
- **Spec: FAIL → FIXED** — criterion 4 (round-trip) violated by a classifier
  echo (see below); everything else met.
- **Risk: PASS** — medium bucket only; no outward actions.
- **Test: PASS** — reviewer independently ran checks (790/1/0 pre-fix); traced
  the index mapping across all four sites (no off-by-one — the
  highest-consequence check, clean); verified applyWholeDocumentSplice refactor
  behavior-preserving (undo grouping, recompute order, flag lifecycle).

## Findings → disposition

1. **BLOCKING — classifier echo on turn-into → Paragraph.** Reviewer repro:
   `turnInto("# > note\n", .paragraph)` → `"> note\n"` reclassifies as quote;
   matrix test's bland `"hello"` fixture couldn't catch it. → **FIXED**
   (`6d83a83`): backslash-escapes (`\#`, `\>`, `\-`, `1\.`, `` \``` ``, `\---`)
   applied per-line when a paragraph-target line would misclassify, reusing
   `NoteDecoration.classify` (access widened, not duplicated). Audit of other
   targets found + fixed a second instance: table-cell ``` joined into a
   codeBlock interior line could close the fence early (NoteDecoration's
   fence-close is a bare-prefix test, so a longer fence would NOT fix it —
   escaped instead). Both reviewer repros are now named regression tests; an
   adversarial round-trip matrix (marker-shaped payloads × source kinds ×
   targets) replaces the bland fixture. 798 tests green post-fix.
2. **NON-BLOCKING — divider menu gating claimed but not implemented** (doc
   comment described view gating that didn't exist; menu showed 10 no-op
   targets on a divider). → **FIXED** (`dc09b45`): `MarkdownBlockRect` carries
   `kind`, gutter hides "Turn into" for dividers, comment corrected; logic-layer
   nil stays as defense in depth.
3. **NON-BLOCKING — missing frontmatter-adjacent byte-pinned test** → **FIXED**
   (`6d83a83`): 2 tests added; code path was already correct.
4. **Judged acceptable** — EOF newline normalization on turnInto (documented;
   per-line explosion makes preserving a missing terminator ill-defined).

## Final: cleared to merge (blocking finding fixed + regression-tested; fix
verified by orchestrator: repro test present, 798/1/0, build clean)
