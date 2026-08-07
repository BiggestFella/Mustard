# BAK-247 — Planning shows duplicate tasks (FOCUS pin re-appears in timeline)

## Diagnosis (code)
Display duplication, NOT data. TodayView renders a focus-starred task in both
`focusSection` and the chronological timeline (`DayPlanner.tasksForDay`). The code
comment (TodayView.swift ~190) calls this out as deliberate, anticipating a
"one-line filter later if disliked". RitualPlanner/DayPlanner only mutate tasks
(no insert), so planning never creates a second record — confirms display dup.

## Fix (Option 1 from ticket: filter timeline, keep FOCUS)
- RitualPlanner.timeline(_:day:) — pure, tested: tasksForDay minus focus-starred-today.
- TodayView timeline uses it; empty-state gate also checks focusTasks so a fully-pinned
  day doesn't read as "nothing scheduled".

## Mobile parity
MobileTodayView has NO FOCUS section — it renders the timeline once, so there is no
duplication to fix; filtering there would HIDE the tasks (regression). Left unchanged;
the single-render rule already holds on mobile. Chose Option 1 over dropping the FOCUS
section because FOCUS is tied to the shipped morning ritual.

