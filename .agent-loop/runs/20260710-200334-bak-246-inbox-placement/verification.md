# Verification — BAK-246

## Required checks (.agent-loop/checks.yml)
- `swift build` → **Build complete** (only pre-existing GoogleAuthSession await warning).
- `swift test` → **692 passed, 1 skipped, 0 failures**.
- lint → no linter configured (no-op).

## New tests (PersonalBoardPlacementTests, 6 cases)
- scheduled + untimed + inbox → planned
- scheduled + timed + inbox → scheduled
- unscheduled inbox → stays inbox
- scheduled non-inbox (needsApproval/queued/inProgress/done/planned/scheduled) → stage untouched
- idempotent
- migration repairs stranded inbox cards (untimed→planned, timed→scheduled) while
  leaving untriaged + done rows alone

## iOS
`build-ios.sh` (xcodegen + xcodebuild) not run in-session (no iOS toolchain here; per
CLAUDE.md mobile is eye-verified + CI). Mobile change (MobileWeekView.schedule) mirrors
the desktop helper call and matches the existing `PersonalBoard.matchesArea` in-module
usage pattern.

## Prerequisite
Built on PR #85 (Theme.Motion hotfix) — main did not compile before it.
