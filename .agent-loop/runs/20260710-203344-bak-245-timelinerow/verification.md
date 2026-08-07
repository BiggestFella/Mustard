# Verification — BAK-245
- swift build: clean · swift test: 696 pass/1 skip/0 fail (views build+eye-verified, not unit-tested per CLAUDE.md)
- New shared components: TaskRowDensity, PriorityFlag, MetaChip, TaskChipRow (Views/TaskChips.swift); FlowMeta widened private→internal to share with board card.
- iOS: MobileTodayView.row mirrors desktop via shared public chips; build-ios.sh NOT run in-session (no iOS toolchain) — Leon eye-check pending on both platforms.
- Dead code: ListBadge now unused (was only in old TimelineRow); left in place to avoid touching the iOS project file list.


## Post-review fixes (fresh-context review PASS, no blockers)
- Restored a 'Blocked' signal as a shared chip in TaskChipRow (shown any owner) — the mobile gatePill previously showed it; now both platforms do.
- board card adopts the shared PriorityFlag (removed its private duplicate) so the flag can't drift between row/card.
- TaskChipRow.hasChips gate: a bare task shows no empty chip strip.
- Deleted orphaned ListBadge.swift (sole caller was the old row).
