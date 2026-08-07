# Verification — BAK-247
- swift build: clean
- swift test: 694 passed, 1 skipped, 0 failures (2 new RitualPlanner.timeline tests)
- New tests: excludes today's focus-starred tasks from timeline; preserves chronological order
- iOS: no change (no FOCUS section on mobile → no dup); build-ios.sh not run in-session

