# F27 — Console / board attention consolidation (design)

**Status:** Approved by Leon 2026-07-24 (brainstorming session). Supersedes the
2026-07-23 handover stub. Ready for an implementation plan.

Scope is **presentation / information-architecture only** — no execution-semantics,
gating (ADR-0006), or delegated-lifecycle (F24) changes.

## Problem

While triaging a voice-routed capture, Leon noticed that a task **needing his
review or approval shows up in the Agent Console looking like the other triage
cards** — work that is *mid-execution* is visually indistinguishable from
*proposals not yet started*.

Verified in code (2026-07-23/24), the deeper issue is that **four different things
can "need you," split across the console and board inconsistently**:

| Needs you | Kind | Console (today) | Board (today) |
|---|---|---|---|
| **Recommendations** | pre-execution *proposal* (`Recommendation`, decision `.pending`) | ✅ rich cards | — |
| **Needs Approval** (`.needsApproval`) | approve a prepped run *before* it acts | — | ✅ column |
| **Needs You** (`.needsInput`) | answer the agent mid-run | ✅ attention row | ✅ column |
| **Needs Review** (`.needsReview`) | check finished output | ✅ attention row | ✅ column |

Two concrete defects fall out of that table:

1. **The console omits Needs Approval entirely** — so today you *cannot* approve a
   run from triage, only from the board.
2. The two "waiting on you" counts already **disagree**:
   `AgentInbox.attentionTaskCount` counts only `needsInput + needsReview`, while
   `PersonalBoard.waitingCount`/`agentBadge` (via `needsHuman`) count all three
   gate stages including `needsApproval`.

Plus the original complaint: mid-execution gate rows use the same compact-card
treatment as proposal cards, blurring the phase boundary.

## Decisions (from the session)

- **Keep the double-surface — do not remove it.** Every gate must be actionable
  from **both** the console (triage) and the board; because both surfaces are
  projections of the same `task.stage`, acting in one place makes the item leave
  the other automatically. This is the desired behaviour, not a bug.
- **Console left column = two tiers:** *In flight — needs you* (all three pipeline
  gates as compact, actionable, visually-distinct rows) above *Recommendations*
  (unchanged rich proposal cards).
- **Every gate row carries both affordances:** a trailing one-click primary button
  *and* an expand-to-sheet. The button does the primary decision; expanding opens
  the full flow.
- **Console gains Needs Approval**, closing defect #1.
- **Counts unify** on the board's definition (all three gate stages + pending
  recs), closing defect #2.

## Core principle — one field, two projections

The console's in-flight list and the board's columns both *derive* from a single
source of truth: **`task.stage`**. Every console gate action calls the same
stage-advancing logic the board already uses (`PersonalBoard.approveTarget`), so:

- Approve/Accept in the console → stage advances → the task drops out of the
  console list *and* leaves its board gate column, with no cross-surface
  bookkeeping.
- No new model, no new review object (ADR-0010 preserved — the console rows are
  the same `MustardTask`, opening the same `ConsoleTaskSheet` → `TaskDetailSheet`).

## Design

### 1 · Console left column: two tiers

Replace today's two separate `NEEDS YOU` / `NEEDS REVIEW` sections
(`AgentConsoleView.masterColumn`, lines ~73-79) with:

- **Tier 1 — "In flight — needs you" (N):** one list rendering
  `AgentInbox.attention(_).inFlight`, oldest-first (longest-waiting leads — the
  existing convention). The gate-colored spine does the kind-grouping visually, so
  a single flat list is enough. *(Alternative considered: weight ordering by kind;
  rejected as unnecessary for now — YAGNI.)*
- **Tier 2 — "Recommendations" (N):** unchanged — `RecommendationRow` rich proposal
  cards, `SourceGrouping`, provenance, confidence bars.

### 2 · Gate-row treatment (`gateRow(_:)`, replaces `attentionRow(_:)`)

A compact row, deliberately *not* a proposal card — no sparkles, no confidence bar:

- **Gate-colored left spine** (3pt, rounded), keyed to stage, all from `Theme`:
  - `.needsApproval` → `Theme.Palette.agent` (`#7F77DD`, purple)
  - `.needsInput` → `Theme.Palette.warning` (`#D98A29`, amber)
  - `.needsReview` → `Theme.Palette.done` (`#1D9E75`, green)
- Area color dot (as today), single-line title, and a muted sub-meta line
  (e.g. "gated · draft ready", "agent asked · 2h ago", "finished · check the output").
- **Trailing primary button** whose label + behaviour come from the gate (see §3).
- **Whole-row tap and a trailing ⋯/expand both open `ConsoleTaskSheet`** (the full
  conversation + all secondary actions).

Card chrome stays Things-3-calm: `Theme.Palette.surface`/`bg` fill, 0.5pt
`hairline` border, existing radii. No hardcoded colours.

### 3 · Inline action model

A new **pure** helper maps stage → button, so the view stays dumb:

| Stage | Button label | One-click? | Action |
|---|---|---|---|
| `.needsApproval` | `Approve` | yes | advance via `PersonalBoard.approveTarget` (→ `.queued` if gated, else `.needsReview`) |
| `.needsInput` | `Answer` | no | opens `ConsoleTaskSheet` focused on the reply composer (answering is inherently typing) |
| `.needsReview` | `Accept` | yes | advance via `PersonalBoard.approveTarget` (→ `.done`) |

Secondary decisions — Reject/Hold (approval), Request changes/Take back (review) —
live in the expanded sheet, not on the row. The one-click buttons dispatch to a
service method (e.g. `AgentService.advanceGate(_:)` / existing coordinator path)
that applies `approveTarget` and persists; the *decision* stays in pure
`PersonalBoard`, the view only dispatches.

### 4 · Pure logic (TDD, in `Logic/`)

- **`AgentInbox.AgentAttention`** gains `inFlight: [MustardTask]` =
  `needsApproval ∪ needsInput ∪ needsReview`, sorted oldest-first with the `uid`
  tiebreak (same `precedes` rule already in `attention(_:)`). The existing
  `questions` / `reviews` fields are removed if no other caller needs them
  (verify usages during implementation; only `AgentConsoleView` is known to use
  them today).
- **New pure gate-action helper** (name TBD in plan, e.g.
  `AgentInbox.gateAction(for:) -> (label: String, oneClick: Bool)?`), returning
  `nil` for non-gate stages.
- **`AgentInbox.attentionTaskCount`** now includes `.needsApproval`, so
  `waitingCount`, the hover dock, notch ticker, and sidebar badge all match the
  board's `waitingCount`/`agentBadge`.

### 5 · Board

No structural change. Its columns and the "N waiting on you" review-focus pill
already render all three gate stages. The console's one-click buttons reuse
`PersonalBoard.approveTarget`, so both surfaces stay coherent. Blast radius is
confined to `AgentConsoleView` + `AgentInbox`.

### 6 · Voice pairing (spec Q3)

Principle: **one capture, one object.** A voice-routed capture lives as a
`Recommendation` in the console until approved, then promotes to the board — it
should not simultaneously exist as a separate board Inbox task.

Within F27's console-only scope this holds **by construction**: the in-flight tier
shows only the three gate stages (never `.inbox`), so a fresh voice capture appears
once, as a Recommendation. The cross-surface dedup — *not* creating a board Inbox
task while the console still holds the pending rec (the "Email Bree shows twice"
case) — is **deferred to F26** (voice capture), which owns that wiring.

## Testing

Logic is TDD; views are build + eye (Leon confirms — the agent can't screenshot the
native app). New/changed XCTest cases in `Tests/MustardTests/`:

- `attention(_:).inFlight` contains exactly the three gate stages, excludes other
  stages, and is oldest-first with the `uid` tiebreak.
- `attentionTaskCount` includes `.needsApproval` (regression guard for defect #2)
  and now equals `PersonalBoard.waitingCount` for the same task set.
- `gateAction(for:)` returns the correct `(label, oneClick)` for each of the three
  gate stages and `nil` otherwise.
- Existing `AgentInbox` / `RecommendationQueue` tests updated for the new bucket.

## Out of scope (deliberately not built)

- Removing the double-surface (Leon wants gates actionable from both places).
- Any execution-semantics, gating, or delegated-lifecycle change.
- A separate review object / `OutputCard` (ADR-0010).
- Board layout/column redesign.
- The deeper voice cross-surface dedup (owned by F26).
- Kind-weighted ordering within the in-flight tier.

## Related

- `Sources/MustardKit/Views/AgentConsoleView.swift` — `masterColumn`,
  `attentionRow` → `gateRow`, `sectionLabel`, `RecommendationRow`.
- `Sources/MustardKit/Logic/AgentInbox.swift` — `attention`, `attentionTaskCount`,
  `waitingCount`, `dockText`.
- `Sources/MustardKit/Logic/PersonalBoard.swift` — `approveTarget`, `gateStages`,
  `waitingCount`/`needsHuman`, `agentBadge`.
- `Sources/MustardKit/Models/TaskStage.swift` — gate stage labels/kinds.
- ADR-0010 (decoupled agent execution / board queue), ADR-0006 (confidence × trust
  gating), ADR-0011 (voice capture — F26).
- Prior console spec: `docs/specs/2026-06-24-agent-recs-master-detail-design.md`.
- `docs/build-order.md` → F27 entry.
