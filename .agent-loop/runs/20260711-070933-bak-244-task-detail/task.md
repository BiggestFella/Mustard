# BAK-244 — Opened-task detail design pass (personal tasks)
Brainstormed with Leon; he chose **live-edit, restyled** (not read-first) and approved the
mockup + build. Behaviour unchanged (every field editable on open); layout/styling only.

## Desktop TaskDetailSheet (canonical surface)
- New header: stage badge + owner row; large editable title (docH1) with inline
  PriorityFlag; at-a-glance TaskChipRow (shared BAK-245 vocabulary).
- Body → calm labelled sections (DETAILS + SUBTASKS + LINKS + NOTES) separated by
  hairlines, replacing the grey settings-card look. All live controls preserved.
- Kept: agentContext (WHY/draft/confidence/gated) — de-duplicated its stage badge
  (header owns it now); stage-adaptive footer (BAK-136) untouched.
- Removed dead `field` helper (title moved to header). Sheet 460x600.

## iOS MobileTaskSheet (parity)
Already sectioned/read-styled; mirrored the header — inline PriorityFlag + shared
TaskChipRow — so both platforms share the look. Mobile stays read+action (its existing
model); full mobile live-edit is out of scope for this restyle.

