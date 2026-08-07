# Fresh-context review — BAK-253 (b219223..HEAD on agent/bak-253-format-toolbar)

Reviewer: fresh-context sonnet subagent, 2026-07-12.

- **Standards: PASS** — pure logic in Logic/ (no AppKit), view render+dispatch
  only, span grammar reused not duplicated (.link's minimal own grammar is
  correct since NoteDecoration never modeled `[text](url)`).
- **Spec: PASS** — all six task.md criteria met and verified in code (re-parse
  wrap guard real with clean nil failure; involution tested for all six kinds;
  live selection read at click time; toolbar/slash-menu overlap structurally
  impossible via disjoint selection-length guards; ~~~/fence collision ruled
  out empirically).
- **Risk: PASS** — Sources/+Tests only, medium bucket, no outward actions.
- **Test: PASS** — reviewer ran checks independently (835/1/0, build clean).

## Findings → disposition (all NON-BLOCKING)

1. `==` highlight false-positive on prose with two comparisons per line
   (reproduced: "a == b, c == d" matches "== b, c ==") — same
   symmetric-delimiter tradeoff italic already carries, but likelier in
   technical prose → **appended to BAK-254** with fix idea + missing regression
   test.
2. `refreshFormatBar` adds a second O(doc) blocks() scan per selection change,
   same cost class BAK-254 item 1 tracks → **appended to BAK-254** (fix both
   with one cached partition).
3. Outer-selection unwrap tested for 3 of 5 symmetric kinds (shared code path,
   low risk) → noted in the BAK-254 comment.

## Verdict: APPROVE-WITH-FOLLOW-UPS (0 blocking; follow-ups filed on BAK-254)
