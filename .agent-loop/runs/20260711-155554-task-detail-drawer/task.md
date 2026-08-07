# Task detail → docked right-side drawer (BAK-244 follow-up, Leon request)
Leon asked (during eye-check) that opening a task use a right-side panel drawer instead
of a centered modal sheet; approved the docked/reflow style in the running app.

## Approach
- New reusable `.taskDetailDrawer(item:)` modifier (TaskDetailDrawer.swift): wraps a
  surface in an HStack and docks TaskDetailSheet (460 wide, full height) on the right,
  reflowing the content beside it; slide+fade transition on the app's expand motion token.
- TaskDetailSheet: added `onClose` callback (drawer owns dismissal; `close()` = onClose
  ?? `@Environment(\.dismiss)` fallback), and made height fill (dropped fixed 600).
- Swapped all 5 `.sheet(item:)` presentations → `.taskDetailDrawer(item:)`:
  TodayView, WeekView, BoardView, ListContentView, and RootView (notch-opened path).
- Local per-screen selection state unchanged (no state lifting) → low blast radius.

## Scope
Desktop only. iOS MobileTaskSheet keeps its bottom sheet (correct for touch); a right
drawer is a desktop concept.

