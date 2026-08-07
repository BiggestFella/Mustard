# Fresh-context review — BAK-250 (b683c5a..HEAD on agent/bak-250-hidden-markdown)

Reviewer: fresh-context sonnet subagent, 2026-07-12.

- **Standards: PASS** — pure decision layer in Logic/ (no AppKit import),
  presentation in the view; reuses existing Block/Span machinery; no unrelated
  refactors.
- **Spec: PASS** — all six task.md acceptance criteria met; checkbox-bracket
  exclusion judged a legitimate scope reading (no distinct bracket span exists
  today), follow-up filed.
- **Risk: PASS** — Sources/ medium bucket only; declared risk:medium matches;
  no outward actions.
- **Test: PASS** — reviewer independently ran checks (728/1 skip/0 fail; build
  clean); coverage judged thorough; noted one missing marker-only-line fixture
  (guard is pre-existing untouched code — not blocking).

## Adversarial checks that came back clean

Glyph-flag ordering correct at every callsite (decorations/fonts before
visibility flags); undo/redo routes through textDidChange + debounced full
pass; copy/paste + Save see full markdown (glyph-level flags only);
CardLayoutManager ranges disjoint from hidden markers; focusedBlockIndices
boundary rule byte-for-byte consistent with pre-existing caretBlock.

## Findings → disposition

1. **NON-BLOCKING** stale-baseline race window in `textViewDidChangeSelection`
   during doc-replace (benign, self-healing) → **FIXED INLINE** (`b896a58`,
   guard extended to `isProgrammaticUpdate`; full suite re-run green).
2. **NON-BLOCKING** O(doc) block re-scan per caret move on large-but-under-limit
   notes → filed **BAK-254**.
3. **NON-BLOCKING** cmd-tab-away may not hide markers (first-responder vs
   window-key semantics; unverifiable in-session) → noted in **BAK-254** for
   Leon's eye-check.

## Verdict: APPROVE-WITH-FOLLOW-UPS (0 blocking; follow-ups filed/fixed)
