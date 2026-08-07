# Verification — task detail right drawer
- swift build: clean · swift test: 696 pass/1 skip/0 fail (views build+eye-verified)
- Eye-check: Leon confirmed in the running app ('much better') — docked reflow, slide-in, full-height footer.
- No behaviour change to the sheet's controls/actions; only presentation + close plumbing.
- iOS unchanged; build-ios.sh not run in-session.


## Post-review (fresh-context PASS, no blockers)
- Added .id(task.uid) to the drawer's sheet so swapping tasks in place re-seeds scheduled/due @State (was the one nit that touched the main swap flow).
- Noted behavior change: for the 4 in-screen drawers, SourceLinkButton now routes source-open to the docked source inspector (they render inside RootView's .environment(sourcePanel)) rather than the external browser — an improvement; notch drawer still falls back to the browser.
