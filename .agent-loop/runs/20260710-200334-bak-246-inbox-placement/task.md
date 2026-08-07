# BAK-246 — Scheduled tasks stuck in Inbox → auto-place into Planned/Scheduled

Invariant: a task with `scheduledAt != nil` is never in `.inbox`; it belongs in
`.scheduled` when `isTimed`, `.planned` otherwise. Inbox = untriaged only.

## Approach
1. `PersonalBoard.normalizePlacement(_:)` — canonical pure helper (unit-tested).
2. Call at every `scheduledAt` write site, replacing scattered/inconsistent
   inline `stage = .planned` snippets (which ignored `isTimed`).
3. `BoardMigration.normalizeScheduledPlacement(_:)` — one-time launch repair for
   already-stranded rows, after the stage backfill.

## Ambiguity resolved
Board card 🗓 chip renders `task.scheduledAt` (MustardBoardCard.swift:162), so the
stranded Inbox cards genuinely carry a scheduledAt → pure placement bug, not a
due-vs-scheduled display mixup.
