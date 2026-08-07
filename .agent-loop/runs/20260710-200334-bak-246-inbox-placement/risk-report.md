# Risk — BAK-246

- Declared labels: none.
- Touched paths: Sources/MustardKit/Logic/{PersonalBoard,BoardMigration,RitualPlanner,DayPlanner}.swift,
  Sources/MustardKit/MustardContainer.swift, Sources/MustardKit/Views/{TaskDetailSheet,QuickCaptureField,
  CommandBarView,RecommendationDetailView,WeekView}.swift, Sources/MustardMobile/MobileWeekView.swift,
  Tests/MustardTests/PersonalBoardPlacementTests.swift.
- path_risk: `Sources/` → **medium**. No high-risk paths (no auth/oauth/ClaudeRunner/
  TrustPolicy/RecommendationAction). Tests/ → low.
- **Highest risk class: medium** → auto-merge eligible (no deep-review panel).
- Data migration touches the store but only moves scheduled tasks out of `.inbox`
  (idempotent, self-correcting, reversible).
- Irreversible outward actions: none.
