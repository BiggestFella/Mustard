# BAK-245 — TimelineRow condensed detail-card styling
Approved design (mockup 2026-07-09). Row = checkbox + bold title (~15.5pt semibold) +
inline HIGH/URGENT flag + wrapping pill chips (time·due·estimate·area·agent-stage·
subtasks). Time is a chip (gutter dropped). Density condensed default + tighter variant.
Hover = warm panel. Chips reuse board-card Theme tokens + FlowMeta wrap.

## Scope reality
TimelineRow is shared by Today + Lists (ListContentView), not Week — Week uses its own
WeekBlock (left as-is; different narrow-column layout the mockup didn't target). Mirrored
the treatment to the iOS Today row (MobileTodayView.row) via the shared public chips.

