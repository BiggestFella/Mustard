# Meeting task approval gate and hourly import

**Date:** 2026-08-14
**Status:** Implemented 2026-08-14
**Author:** Codex with Leon

## Problem

The curated meeting ledger is useful, but Mustard currently treats every
unchecked meeting checklist line as immediately runnable agent work. That lets
low-value or ambiguous items consume a Claude turn before Leon has decided that
the item is worth doing.

The existing 60-second source loop also imports meeting files more frequently
than Leon needs. The import itself is local file I/O, so changing the cadence is
primarily a batching/responsiveness choice rather than a direct token-saving
mechanism. The human gate is the token-saving control.

## Decision

1. Keep the curated `## Code Heroes tasks` ledger as the source of meeting
   tasks.
2. Import new unchecked meeting tasks as agent-owned `needsApproval` tasks.
   `needsApproval` is already excluded from `AgentTaskQueue`, so importing a
   task cannot start Claude work.
3. Approving an agent-owned task moves it to `queued`, where the existing
   executor can run it, and persists `agentApprovalGranted`. Personal/non-agent
   approval transitions remain unchanged.
4. Denying a meeting task writes the unobtrusive marker
   `<!-- mustard:ignored -->` to the matching ledger line, snapshots the old
   file first, and then removes the local task. The parser ignores marked lines
   so a later import cannot recreate the decision. The marker is excluded from
   title extraction and origin-key normalization.
5. Meeting import is due at most once per hour, independently of Mustard's
   60-second source tick. The global source tick remains unchanged so other
   source ingestion and housekeeping are not delayed.
6. The delegated executor remains on its existing 2-second polling cadence. It
   is not a material token lever and changing it would only add latency.

Existing meeting tasks from before this change are re-held in `needsApproval`
unless they already carry the persisted approval bit. The runnable queue also
checks that bit, so an old `forAgent`/`queued` row cannot race the hourly import
and start a turn during the migration window. Interrupted unapproved meeting
turns return to `needsApproval` rather than being silently resumed.

## User flow

```text
curated ledger line
        ↓ (hourly local import)
agent-owned · Needs Approval
        ├─ Do → Approved · Queued → Claude execution → Needs Review
        ├─ Don't do → ledger ignored marker + local task removed
        └─ I'll do it → existing take-back flow to personal work
```

## Scope

- `MeetingTaskParser`: recognize and skip the durable ignored marker; preserve
  origin identity when the marker is added.
- `MeetingTaskSync`: create meeting tasks in `needsApproval`; add a safe,
  snapshot-first ignore write-back operation; re-hold legacy runnable meeting
  tasks until approved.
- `MustardTask` / agent queue / coordinator: persist and enforce the explicit
  meeting-task approval bit across queue selection, app restart, and take-back.
- `PersonalBoard`: agent-owned approval gates queue for execution.
- Desktop and mobile gate actions: use the ignore write-back before deleting a
  denied meeting task; ordinary non-meeting deletions retain current behavior.
- `MustardApp` scheduler: add a pure, unit-tested hourly due check for meeting
  import only.
- Tests and this design note.

## Non-goals

- No changes to upstream Claude scheduled tasks (`triage-meetings`, inbox sweep,
  or Distil).
- No change to email/Jira/Shortcut recommendation cadence.
- No new task stage or separate recommendation type.
- No automatic filtering or model review inside Mustard beyond the explicit
  human gate.

## Failure handling

- If a ledger line cannot be found or the snapshot/write fails, the local
  meeting task is retained and no deletion is performed.
- If the marker is already present, the ignore operation is idempotent.
- Existing completion write-back continues to require the exact `meeting`
  source, so ignored/archived tasks cannot tick a ledger line as completed.

## Verification

- Unit tests cover parser skipping, stable origin keys, snapshot-first ignore
  write-back, needs-approval import, agent-owned approval routing, and hourly
  cadence boundaries.
- Run the focused tests, then `swift build` and the full `swift test` suite.
