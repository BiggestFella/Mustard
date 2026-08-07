# Fresh-context review — BAK-251 (92c61df..HEAD on agent/bak-251-insert-menu)

Reviewer: fresh-context sonnet subagent, 2026-07-12.

- **Standards: PASS** — logic in Logic/, view renders/dispatches only, Theme
  tokens used, exactly the declared files touched.
- **Spec: PASS** — all six task.md criteria met; round-trip guard exceeds the
  ask; Video/Audio/File/Mermaid correctly absent; table left plain-rendered per
  the criterion's own escape hatch. Criterion 6's "existing tests pass
  unmodified" judged literally unsatisfiable given the intentional
  heading→heading(1-4)/todo→checkList renames — wording nit, not a defect.
- **Risk: PASS** — medium bucket only, no high-risk keywords, no outward actions.
- **Test: PASS** — reviewer compared old vs new test file test-by-test:
  strengthening only, byte-exact templates for all original commands; reviewer
  independently ran the suite (747/1/0) and build.

## Findings → disposition

1. **NON-BLOCKING** — keyboard highlight can scroll off-screen (16 rows overflow
   the 360pt cap, no auto-scroll) → **FIXED INLINE** (`a04f7eb`,
   ScrollViewReader + scrollTo on selection change; build + full suite re-run
   green).

## Verdict: APPROVE-WITH-FOLLOW-UPS (0 blocking; sole finding fixed inline)
