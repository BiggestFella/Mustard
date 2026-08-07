# F27 — Console / board attention consolidation (design handover)

**Status:** Planning — not yet designed or built. Raised by Leon 2026-07-23 while
testing voice capture (F25/F26). This doc is a starting point for a fresh planning
session; nothing here is decided.

## The problem (what Leon observed)

While triaging a voice-routed capture, Leon noticed that a task **needing his review
or approval shows up in the Agent Console looking like the other triage cards** — i.e.
work that's *mid-execution* is visually indistinguishable from *proposals not yet
started*, and some of it double-surfaces (also on the board). His words: "anytime a
task is needing my review or approval, it also shows in the agent triage, and looking
like the other triage cards. So we may need to change the look of the existing ones."

## Current state (verified in code, 2026-07-23)

The Agent Console's left/master column (`Sources/MustardKit/Views/AgentConsoleView.swift`)
stacks **three visually-similar groups**, in order:

1. **NEEDS YOU** — `attention.questions` = tasks at `stage == .needsInput`
   (agent asked a question, waiting on the human's answer). Rendered by `attentionRow(_:)`.
2. **NEEDS REVIEW** — `attention.reviews` = tasks at `stage == .needsReview`
   (completed agent work awaiting Accept · Request changes · Take back). Also `attentionRow(_:)`.
3. **RECOMMENDATIONS (N)** — `pending` = `RecommendationQueue.pending(recommendations, now:)`
   (proposals **not yet started** — sweep recs, voice-routed recs, etc.). Rendered as the
   rich proposal/triage cards.

Key sources:
- `AgentConsoleView.swift` — `attention` (line ~30), the `NEEDS YOU`/`NEEDS REVIEW`
  section rendering (lines ~73-79), `attentionRow(_:)` (~305), and the recommendation
  master list.
- `Sources/MustardKit/Logic/AgentInbox.swift` — `attention(_:)` returns
  `AgentAttention { questions, reviews }`; `attentionTaskCount(_:)` counts
  `.needsInput + .needsReview`.
- `Sources/MustardKit/Logic/RecommendationQueue.swift` — `pending(_:now:)` (decision
  `.pending`, not `.ignore`, snooze-aware).
- Board columns render the SAME `.needsInput`/`.needsReview` tasks in their stage
  columns (`BoardView` / `MustardBoardCard`), so review/question work appears in **two
  places** (console attention + board column).

### Why the two are different in kind
- **NEEDS YOU / NEEDS REVIEW** are *tasks mid-execution* (`MustardTask`, past the
  proposal stage, carrying an `AgentRun`). They live on the board's pipeline (ADR-0010).
- **RECOMMENDATIONS** are *pre-execution proposals* (`Recommendation`, decision
  `.pending`). Approving one promotes it onto the board.

Same card treatment blurs that phase boundary, and the mid-execution ones double-surface.

## Design questions to resolve (not decided)

1. **Distinct treatment.** Should review/approval *task* rows get a visually distinct
   card from *proposal* cards (different affordances: Accept/Request-changes/Take-back
   vs. Approve/Edit/Reject)? Or a clearer sectioning / different container?
2. **Canonical home.** Which surface owns each phase?
   - Option: proposals live in the **console** (triage is a console job); mid-execution
     review/question tasks live on the **board** (Needs You / Needs Review columns), with
     the console showing at most a compact count/pointer — removing the double-surface.
   - Option: the console stays the single "everything needing me" inbox, but with clear
     visual tiers.
3. **Voice interaction (ties to F26).** A voice-routed capture currently appears as a
   pending Recommendation in the console AND its linked task sits in the board Inbox.
   Decide how that pairing should read so it isn't confusing (see the "Email Bree"
   example from the F25/F26 session).
4. **Naming/counts.** `HoverPanel`/notch/`AgentInbox.attentionTaskCount` all surface
   "waiting on you" counts — keep them consistent with whatever split is chosen.

## Constraints / non-negotiables

- **Things 3 calm** design language — tokens from `Logic/Theme.swift`, no hardcoded
  colours (CLAUDE.md "Design language").
- **ADR-0010** — output review lives in the board's Needs Review stage, not an
  `OutputCard`; don't reintroduce a separate review object.
- **Logic stays pure/tested** — any new bucketing/ordering goes in `Logic/`
  (`AgentInbox`, `RecommendationQueue`, or a new unit) with tests first, not in the view.
- The gating/trust model (ADR-0006) and the delegated-task lifecycle (F24) are unchanged
  by this — F27 is presentation/IA, not execution semantics.

## Suggested first steps for the planning session

1. Read `AgentConsoleView.swift` end to end (esp. `masterColumn`, `attentionRow`, the
   recommendation list) and `AgentInbox.swift` / `RecommendationQueue.swift`.
2. Look at how the board renders `.needsInput`/`.needsReview` (`BoardView`,
   `MustardBoardCard`) to see the double-surface concretely.
3. Decide the IA (questions 1-2 above), then spec the card treatments + any pure
   bucketing helper, then write failing tests, then build. Follow the Logic-TDD rule.

## Related

- `docs/build-order.md` → **F27** entry (the terse stub this expands).
- ADR-0010 (decoupled agent execution / board queue), ADR-0011 (voice capture, the
  session that surfaced this), ADR-0006 (confidence × trust gating).
- Prior console design specs: `docs/specs/2026-06-24-agent-recs-master-detail-design.md`.
