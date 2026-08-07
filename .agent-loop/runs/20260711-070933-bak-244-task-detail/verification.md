# Verification — BAK-244
- swift build: clean · swift test: 696 pass/1 skip/0 fail (views build+eye-verified per CLAUDE.md)
- No behaviour change: all bindings/pickers/toggles/actions and the stage-adaptive footer preserved; live-edit retained per Leon's decision.
- iOS: MobileTaskSheet mirrors the header via shared public components (PriorityFlag/TaskChipRow); build-ios.sh NOT run in-session — Leon eye-check + iOS build pending both platforms.


## Post-review (fresh-context PASS, no blockers)
- Routed all section labels (Details/Subtasks/Links/Body) through the shared sectionHeader helper (DRY nit).
