# Dev-loop Digest

Append-only ledger of merges and holds. Each entry carries a ready `git revert` line.

## 2026-07-24 — MERGED · Fix: compile shared task chips into the iOS target (PR #99)
- **Risk:** low (mechanical file move, no behaviour change) · **Deep-review:** n/a
- **Checks:** macOS swift build clean + swift test 1033 pass/1 skip · **iOS Simulator + device(arm64) CLEAN build SUCCEEDED (fresh DerivedData)** · CI (self-hosted, macOS-only) green 56s
- **Review:** fresh-context APPROVE — byte-compared the moved FlowMeta (identical), confirmed exactly one definition, no AppKit/Views-only deps remain, desktop unaffected; independently reproduced the clean iOS build.
- **Root cause:** `main`'s iOS app did NOT clean-build — MobileTaskSheet/MobileTodayView reference `PriorityFlag`/`TaskChipRow` (BAK-244/245 shared chips) + the `FlowMeta` layout, all living in `Sources/MustardKit/Views/**` which project.yml excludes from the iOS target. Prior `build-ios.sh` passes were stale-incremental-cache illusions. **CI never caught it: the self-hosted CI runs only `swift test`/`swift build` (macOS SPM), never the iOS xcodebuild.**
- **Fix:** moved the shared, pure-SwiftUI UI to a new (non-excluded) `Sources/MustardKit/SharedUI/` — `TaskChips.swift` (git mv, history preserved) + `FlowMeta.swift` (extracted verbatim from MustardBoardCard.swift). Both targets compile it; desktop unchanged (same module).
- **Follow-up (open):** add an iOS `xcodebuild` lane to CI so `Views/**`-boundary regressions can't land silently again.
- **Revert:** `git revert df60dfcf01f64842bd916a529ac16e0cab52e11c`


## 2026-07-06 — MERGED · Craft pass — Theme tokens, surface polish, live Notes editor (PR #78)
- **Risk:** HIGH (new live editing surface over vault files — spec's own call; an earlier
  mechanical-medium classification was corrected after fresh-context review flagged it)
- **Fresh-context review:** standards PASS · spec BLOCK → remediated (Task 11 docs, risk
  call, process drift recorded) — `review-report.md`
- **Deep-review panel:** 2 lenses REFUTED → both findings fixed in-run (stale undo stack
  across note switch → `removeAllActions()` on document swap; /Sub-page file-creation
  inside an undoable edit → dangling-link design), 1 lens UPHELD (no regressions).
  **PASS after fix round** — `deep-review-report.md`
- **Checks:** swift test 647 pass/1 skip (was 576) · swift build clean · macOS CI green on
  final HEAD (`ba02425`, run 28788800603)
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260706-craft-pass/`
- **What landed:** Theme.Elevation/Motion/Metrics + editorial type (+NS bridges); surface
  polish (MarkdownBlocksView extraction, task-notes markdown preview, card depth+hover,
  warmer empty states); live Craft editor replacing Source/Preview (TextKit-1
  MarkdownTextView over pure NoteDecoration spans — no rewrite API; SlashMenu;
  byte-pinned BlockReorder + hover gutter; subpage cards). Spec Phase 3 (Daily Note)
  pinned/deferred. Single-PR delivery per Leon's "build the whole thing".
- **Merge:** Leon reviewed the process (CI green, fresh-context review, deep-review panel
  pass after fix round) and authorized the merge directly — the planned "eye pass" in the
  running app happens after, on main, rather than gating the merge itself.
- **Follow-ups (non-gating, from the panel):** CRLF-aware BlockReorder terminator hygiene;
  close the one-runloop ⌘S save window during note switch; guard textViewDidChangeSelection
  with isProgrammaticUpdate; hasMarkedText() checks around the slash menu; surface failed
  note creation (currently a silent no-op); strip frontmatter before block-rendering
  task.notes in TaskDetailSheet; delete or repurpose the now-uncalled MarkdownPreviewView.
- **Revert:** `git revert 117db0e95cac50f20115d66f9eaf10ec424cec8c`

## 2026-07-06 — MERGED · BAK-50 Morning ritual — "Plan your day" wizard (PR #77)
- **Risk:** medium (feature; Sources/ only — zero high-risk paths, wizard calls only existing decision APIs) · **Fresh-context review:** PASS (4/4 axes)
- **Checks:** swift test 576 pass/1 skip (was 556) · swift build clean · build-app.sh OK · CI (self-hosted) green
- **Outward actions:** none · no claude invocations added; all mutations local SwiftData/UserDefaults
- **Run:** `.agent-loop/runs/20260706-morning-ritual/`
- **What landed:** four-step wizard (rollover review w/ stamped carry-forward · inline agent standup · pick-today + capacity line · 1–3 focus stars via auto-expiring `focusOnDay`); gentle-prompt entry (Today banner + notch line gated by pure `RitualPrompt`, ⌘K always-available by design); FOCUS group pinned on Today; notch prefers open focus task. Spec + plan in docs/. Brainstormed with Leon (6 recorded decisions); evening shutdown deliberately deferred.
- **Process:** 7 plan tasks, fresh Opus implementer + two-stage review each; 4 review-driven fix commits (open-star focus cap, plannedToday→Logic, standup copy, channel-key constant); post-review hardening (midnight-boundary test, spec text reconciled).
- **Known limitations:** ⌘K re-plan ungated (deliberate); vaultNote approval in standup uses the console-parity claude path; FOCUS duplicates in timeline (flagged for Leon's eye); overnight-idle banner staleness until next render.
- **Follow-ups:** evening shutdown ritual (new backlog issue); ritualSubtitle into Logic; mobile ritual UI slice; optional launch-clear of the ⌘K trigger flag; Leon eye-check (banner, wizard steps, FOCUS, notch line).
- **Revert:** `git revert cc88b1a2e6838ae4fb47e0199a0966dac36d0b9e`

## 2026-07-06 — MERGED · Notes Phase A hygiene follow-ups + BAK-71 calendar polish (PR #76)
- **Risk:** HIGH by path letter ("auth" substring via test-only GoogleAuthSessionTests stub dedup) · **Deep-review:** PASS (1 block → fix round → 3/3 clear)
- **Checks:** swift test 556 pass/1 skip (was 535) · swift build clean · CI (self-hosted) green
- **Outward actions:** none · zero production auth code touched (panel-verified)
- **Run:** `.agent-loop/runs/20260706-notes-hygiene/`
- **What landed:** reindex change-guard (skip no-op rebuilds; force-path for ⌘K + parserVersion salt + stat-before-read after panel block), any-level note-title derivation, CRLF-tolerant parsing, Theme.Palette.error + SourceSettingsView migration, shared StubRedirectServer, CalendarWindow half-open doc (BAK-71 closed)
- **Panel value note:** the correctness panelist caught that the change-guard would have made this PR's own parser fixes unreachable for existing indexed notes — the exact class of bug deep-review exists for
- **Follow-ups:** migrate remaining #D85A30 in AgentConsoleView + MobileBoardView to Theme.error (platform parity); write parser version after first full pass (residual crash-window); test-suite UserDefaults teardown hygiene
- **Revert:** `git revert 9d065c9991557edab330db789e091db571d069dc`

## 2026-07-05 — MERGED · BAK-145 Notes Phase A — vault-backed markdown notes (PR #74)
- **Risk:** medium (feature; Sources/ only — no high-risk paths) · **Fresh-context review:** PASS (4/4 axes)
- **Checks:** swift test 535 pass/1 skip (was 447) · swift build clean · build-app.sh OK · CI (self-hosted) green
- **Outward actions:** none · all writes stay inside project working dirs + local SwiftData
- **Run:** `.agent-loop/runs/20260705-notes-phase-a/`
- **What landed:** NoteVaultIO whole-vault scanner; WikilinkIndex link graph (+ shared WikilinkSyntax grammar); MarkdownBlocks preview parser; NoteIndexEntry mirror + NoteIndexService (300s throttle, on-save, ⌘K reindex); Notes tab (project sidebar/folder tree/filter); raw+preview editor with snapshot-guarded save; backlinks panel with snippets; wikilink navigate + create-from-unresolved; "+" note creation. Spec addendum + plan in docs/. BAK-146→153 closed.
- **Process:** 9 Opus implementer subagents, TDD each, two-stage review per task (spec + quality) with 8 review-driven fix commits, whole-feature fresh-context review.
- **Known limitations:** edits drop on tab-switch/app-quit (note→note protected); reindex rewrites unchanged rows (needs change-guard before CloudKit N2); reindex/save IO synchronous on main actor; duplicate-title first-match; CRLF frontmatter unparsed.
- **Follow-ups:** autosave/onDisappear save in NoteEditorView; skip no-op reindexes via lastModified compare; extract save-flow decision into Logic/; unify title derivation (index H1-only vs editor H1–H6); Leon eye-check of all Notes surfaces.
- **Revert:** `git revert a7e01c7d00708b9bb8bb583a07b94f59b3a206d4`

## 2026-07-01 — MERGED · Docs: mark Agent worker Phase 3 spec Implemented (PR #70)
- **Risk:** low (docs-only, 1 line) · **Deep-review:** n/a · **Checks:** CI (self-hosted) green 47s
- **What landed:** base Phase 3 spec status Draft→Implemented (the worker is the live-tested local-only vault skill `drain-agent-queue`, enhanced per the skill-aware design); notes the deferred items (scheduled routine; KBs beyond DL). Corrects a stale doc that had wrongly read as open backlog.
- **Revert:** `git revert 8109be4d83d4a7bbd663d30646edcbf5b47ae822`


## 2026-07-01 — MERGED · Cleanup: triage/week polish + hand-off gate (PR #69)
- **Risk:** medium (shared MustardKit Logic + desktop Views + mobile Views; one behaviour change: BAK-95 gate) · **Deep-review:** n/a
- **Checks:** swift test 433 pass/1 skip (+7: 2 WeekPlanner subtask, 5 SnoozeTargets) · swift build clean · build-ios.sh BUILD SUCCEEDED · CI (self-hosted) green 44s
- **Review:** fresh-context APPROVE, no blockers. Verified subtask exclusion doesn't drop scheduled subtasks from day columns; SnoozeTargets semantics preserved at all 4 call sites; MobileAreaChips both callers updated + orphan queries removed; skipped-materializeTask reasoning confirmed (inverse would mislabel accepted create_task as delegated). Folded in the one completeness note: extended the Stage-picker gate from 2→4 agent lanes (forAgent/needsApproval/queued/needsReview) to exactly match the board drop guard.
- **Outward actions:** none.
- **What landed (Leon-directed cleanup pass):** WeekPlanner.unscheduled/overdue exclude subtasks (parent==nil) → Week rail shows top-level only (desktop+mobile); new tested SnoozeTargets (nextNineAM/tomorrow9/evening) replacing 4 inline copies; new shared MobileAreaChips (Week+Board); **BAK-95** — TaskDetailSheet Stage/Assignee pickers gate an area-less agent hand-off with inline hint (was a silent bypass).
- **Deliberately skipped:** linking rec.task in AgentService.materializeTask (inverse task.delegation would mislabel accepted create_task as agent-delegated; mobile undo uses identity-diff so it's unneeded).
- **Known non-blocking (review-flagged):** an independently-scheduled *overdue* subtask now renders in its past day column instead of the rail (unlikely data shape; current/future columns unaffected).
- **Revert:** `git revert 85b27cbdb852d6769c552c1acaef78dcbd27447f`


## 2026-07-01 — MERGED · BAK-119 iOS Triage swipe deck (PR #68) — **iOS companion COMPLETE**
- **Risk:** medium (iOS UI + small MustardKit logic: TriageDeck + TrustLevel.next + a shared enum label; macOS views untouched) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 426 pass/1 skip (+4 net: TriageDeckTests) · swift build clean · build-ios.sh BUILD SUCCEEDED · CI (self-hosted) green 48s
- **Review:** two fresh-context passes (original deck, then Leon-feedback rework) — both APPROVE. Verified gated approve on iOS sends nothing (decide→promote to .queued/.agent, no claude run); undo captures the approve-created task by identity-diff and deletes exactly it (fixed the review's orphaned-task follow-up — createTask never links rec.task); onEnded flinging-guard; no Button-in-Button. **Eyeballed + iterated with Leon** (removed gated-safety, enriched card, smoothed animation — "yeh its better im happy enough").
- **Leon feedback folded in:** (1) dropped gated-swipe-safety — swipe/✓ approve gated too (still only queues, never sends from phone); kept "Gated" tag as info. (2) richer deck card: proposed-draft preview + source context/Open link + area/recency. (3) re-bucket = full action set (desktop parity); **RecommendationAction.ticket label "Shortcut ticket" → "Create Shortcut" (shared → desktop too, per Leon's desktop/mobile parity rule)**. (4) animation smoothed: live drag tracks finger 1:1 (removed implicit .animation on drag), fling applies on completion callback (not a fixed sleep), spring snap-back + restack.
- **Outward actions:** none · approving records decisions / queues in SwiftData; nothing sends from iOS.
- **What landed:** MobileTriageView upgraded from the interim list to a Tinder deck (swipe R=approve/L=reject/down=snooze, tap=BAK-115 sheet, drag hint overlays, trust tap-cycle via applyTrust, one-tap Undo, manual ✗/💤/✓ buttons) + pure TriageDeck.outcome + TrustLevel.next.
- **Milestone:** BAK-119 was the last iOS screen. **2026 redesign now COMPLETE on desktop + mobile** (Today/Week/Board/Triage all shipped, at feature parity). Still Leon-gated for real devices: BAK-46 CloudKit sync + Apple Developer Program (TestFlight/signing).
- **Non-blocking follow-up (pre-existing):** AgentService.materializeTask doesn't set rec.task (desktop createTask-approve leaves rec↔task unlinked); mobile undo works around it via identity-diff, but linking it would be cleaner.
- **Revert:** `git revert 8f1876f73d867abb0350342d5161253e2f144e7a`


## 2026-07-01 — MERGED · BAK-115 iOS triage-detail sheet + interim Triage list (PR #67)
- **Risk:** medium (iOS UI only; no MustardKit, macOS untouched) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 422 pass/1 skip (unchanged — pure mobile Views) · swift build clean · build-ios.sh BUILD SUCCEEDED · CI (self-hosted) green 47s
- **Review:** fresh-context APPROVE, no blockers. Verified all footer actions set a non-`.pending` decision (rec leaves RecommendationQueue.pending); ADR-0003 honored (AgentService injected on iOS, decide() records decision + stages task, sends nothing from phone); action-by-action desktop parity; no Button-in-Button. One nit folded in before merge: "Schedule for tomorrow" → "Schedule" (decide(.scheduled)→nextNineAM() can be today 9am; mobile path is richer than desktop's orphan-task inline — links rec↔task, carries actionType/confidence, routes area). **Eyeballed by Leon ("sure").**
- **Outward actions:** none · records decisions in SwiftData; no send on iOS.
- **What landed:** MobileRecommendationSheet (provenance/SourceBadge, gated banner, action+confidence, WHY, re-bucket chips, original source, editable draft, comment, compact approve/reject/snooze/schedule/self-execute/keep/comment footer via AgentService) + interim MobileTriageView list (pending queue via RecommendationQueue.pending, tap→sheet) replacing the Agent-tab stub; removed dead MobileScreenStub.
- **Next:** BAK-119 upgrades MobileTriageView from a list to the Tinder swipe deck, reusing this sheet.
- **Revert:** `git revert c8e7f4a62da2caabd21becc9556b3dbe12c8d46e`


## 2026-07-01 — MERGED · BAK-116 iOS Week (day-strip + capacity + tap-schedule) (PR #66)
- **Risk:** medium (iOS UI + 1 small pure-logic exposure; macOS views untouched) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 422 pass/1 skip (+3) · swift build clean · build-ios.sh BUILD SUCCEEDED · CI (self-hosted) green 47s
- **Review:** fresh-context APPROVE, no blockers. Verified `schedule(_:)` is behaviour-equivalent to the desktop drop-destination (scheduledAt via scheduleDate, inbox→planned, isTimed untouched → untimed lands "Anytime" but still counts toward capacity); no Button-in-Button double-fire (cards = .contentShape+.onTapGesture); `matchesArea` genuinely tested (all 3 BoardArea cases). **Eyeballed by Leon ("looks good").**
- **Outward actions:** none · additive iOS screen + a public wrapper over the board's existing tested area predicate.
- **What landed:** MobileWeekView (Mon–Sun day-strip w/ per-day load dots, single selected-day plan w/ capacity bar + time-of-day grouping, OVERDUE+UNSCHEDULED rail with tap-to-schedule onto the selected day; no drag/no ✦ Balance — desktop-only; shared area filter w/ Board), wired into MobileRootView (replaced the Week stub), `PersonalBoard.matchesArea` public + MobileWeekTests.
- **Follow-ups (non-blocking, review-raised):** shared MobileAreaChips component (Week/Board duplicate the chip row); subtasks-with-no-schedule show in the rail (shared WeekPlanner.unscheduled behaviour, desktop too — could exclude `parent != nil`); past-day "＋ day" scheduling is allowed (mirrors desktop drop — product glance); duplicate "Personal" chip is a seed artifact shared with Board.
- **Revert:** `git revert f7dd366b54e0137907abd04fae63425e932ba627`


## 2026-07-01 — MERGED · BAK-114 iOS Board (stacked sections) + DEBUG seed (PR)
- **Risk:** medium (iOS UI; macOS untouched) · **Deep-review:** n/a
- **Checks:** iOS build-ios.sh BUILD SUCCEEDED · macOS untouched
- **Review:** round 1 CHANGES-REQUESTED (nested Button-in-Button double-fire + broken WIP) → fixed (card = .contentShape+.onTapGesture, gate Buttons children). Round 2 APPROVE. Seed reviewed APPROVE (DEBUG-gated, empty-store guard). **Eyeballed by Leon ("looks good").**
- **Run:** `.agent-loop/runs/20260701-120900-bak-114-ios-board/`
- **What landed:** MobileBoardView (stacked sections, owner+area chips shared w/ Week, waiting pill, mobile card + inline gate buttons) + MobileSampleData (DEBUG simulator seed across all stages so mobile is verifiable without a create form/CloudKit).
- **Revert:** `git revert 9bf4fcee1688e12dffcd1bbbfdcfe0117f02074a`


## 2026-07-01 — MERGED · BAK-113 iOS Today + shared task sheet (PR)
- **Risk:** medium (iOS UI; macOS untouched) · **Deep-review:** n/a
- **Checks:** iOS build-ios.sh BUILD SUCCEEDED · macOS swift build clean (SPM untouched)
- **Review:** fresh-context APPROVE — DayPlanner/AgentInbox reuse correct, no div-by-zero, footer transitions reuse PersonalBoard/TaskCompletion, deletes .nullify-safe, no force-unwraps; removed a dead @Environment. **Eyeballed by Leon in the simulator ("nice!").**
- **Run:** `.agent-loop/runs/20260701-110602-bak-113-ios-today/`
- **What landed:** MobileTodayView (progress, nudge→Triage, timeline + mobile gate pills, inbox) + MobileTaskSheet (shared task-detail bottom sheet, task half of BAK-115; stage-adaptive footer).
- **For Leon's eye:** confirmed live in sim.
- **Revert:** `git revert 320fadfd3f67b889233dd273b8594327c165c834`


## 2026-07-01 — MERGED · BAK-110 iOS bottom-tab app shell (PR)
- **Risk:** medium (new iOS UI; macOS/SPM untouched) · **Deep-review:** n/a
- **Checks:** iOS build-ios.sh BUILD SUCCEEDED · macOS swift build clean · swift test 419 pass/1 skip
- **Review:** fresh-context APPROVE — one container+AgentService wired (iOS agent = no-op ClaudeRunner stub), TabView Today/Week/Board/Agent, badge derived (pendingRecCount), FAB toast, shared MobileFilters; folded in the nit (auto-dismiss moved to always-present TabView)
- **Run:** `.agent-loop/runs/20260701-104519-bak-110-ios-shell/`
- **What landed:** MustardMobile shell — bottom tabs, Agent badge, FAB ("New task — coming soon"), shared owner/area filters; screens stubbed for BAK-113/114/116/119.
- **Revert:** `git revert aec94e69197ce3f00c22352b877659744048e84b`


## 2026-07-01 — MERGED · BAK-108 iOS app target via XcodeGen (PR)
- **Risk:** HIGH (structural / new build tooling; ADR-0004 boundary) · **Deep-review:** PASS (3/3 clear — correctness, security/risk, spec; both platforms rebuilt independently)
- **Checks:** macOS swift build clean · swift test 419 pass/1 skip · iOS xcodebuild simulator BUILD SUCCEEDED
- **Deep-review:** additive + reversible (Package.swift/checks.yml untouched, .xcodeproj git-ignored, +184/-0); ClaudeRunner macOS Process path byte-for-byte preserved + iOS stub (no execution path); no secrets/signing/CloudKit; folded in portable simulator destination. Report: deep-review-report.md.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-104034-bak-108-ios-target/`
- **What landed:** committed project.yml (XcodeGen) → MustardMobile iOS app compiling the platform-agnostic core (Models+Logic+Agent+MustardContainer, excl Views/); ClaudeRunner Process #if os(macOS)+iOS stub; build-ios.sh; ADR-0004 update note. Stub MobileRootView proves core linkage.
- **Unblocks:** BAK-110 (iOS shell) → 113/114/115/116/119. CloudKit BAK-46 still needs Apple Dev entitlements (Leon).
- **Revert:** `git revert 2382efe64151047f18878505da50c98c56bba4f5`


## 2026-07-01 — MERGED · BAK-133 standalone Settings screen (PR)
- **Risk:** medium (Improvement; new SettingsView + RootView) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 419 pass/1 skip
- **Review:** fresh-context APPROVE — settings excluded from .primary (no double nav), all MustardScreen switches handle it, trust binds same @AppStorage as console (in sync, no gating change), SourceSettingsView embeds cleanly (env provided), dock hidden on settings
- **Run:** `.agent-loop/runs/20260701-101425-bak-133-settings-screen/`
- **What landed:** dedicated Settings screen (sidebar ⚙, pinned) = Sources + Trust; additive per CLAUDE.md (trust in console AND settings). Per-source Connected indicators left as-is (noted).
- **Revert:** `git revert 3fcbb41c58453129a5c27115cbe49cc1681b6a4f`


## 2026-07-01 — MERGED · BAK-137 detail read-only agent approval context (PR)
- **Risk:** medium (Feature; TaskDetailSheet view) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 419 pass/1 skip
- **Review:** fresh-context APPROVE — read-only additive section, nil-safe, confidence bars in-range, Theme tokens, doesn't disturb form/footer; no mode-toggle (deliberate), output block N-A per ADR-0010
- **Run:** `.agent-loop/runs/20260701-093829-bak-137-approval-context/`
- **What landed:** read-only agentContext (stage badge, gated notice, confidence, WHY, draft) shown when the task carries agent context.
- **Revert:** `git revert 83dd115267328fec60ebc7cda0b2fbdbb90d252f`


## 2026-07-01 — MERGED · BAK-136 detail stage-adaptive footer matrix (PR)
- **Risk:** medium (Feature; TaskDetailSheet) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 419 pass/1 skip
- **Review:** fresh-context APPROVE — switch exhaustive (default catches non-proposed inbox), each branch matches the matrix, transitions reuse approveTarget/move (non-forked), dismiss semantics safe, deletes .nullify-safe, Theme tokens
- **Run:** `.agent-loop/runs/20260701-093418-bak-136-footer-matrix/`
- **What landed:** six-branch stage-adaptive footer (needsApproval/needsReview/queued/forAgent/proposed-inbox/your-tasks) with takeOver/approveGate/scheduleTomorrow helpers.
- **Revert:** `git revert e146ecbc13915e271f0c9ae37683f7cc2703faff`


## 2026-07-01 — MERGED · BAK-134 board + New task + Search (PR)
- **Risk:** medium (Feature; BoardView + PersonalBoard helper) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 419 pass/1 skip (+2 filterBySearch tests)
- **Review:** fresh-context APPROVE — filterBySearch pure+tested (empty→all, case-insensitive), +New task insert-then-edit consistent with QuickColumnAdd, layout balanced; folded in the reviewer's nit (suppress Done "+N older" tail while searching)
- **Run:** `.agent-loop/runs/20260701-092926-bak-134-newtask-search/`
- **What landed:** header "+ New task" (insert inbox task + open sheet) + Search field filtering each column via `PersonalBoard.filterBySearch`.
- **Revert:** `git revert abcbf0cac025a73c9d91faa8f704609ce55616fb`


## 2026-07-01 — MERGED · BAK-131 contextual 'Approve & run' label (PR)
- **Risk:** low (Improvement; RecommendationDetailView label) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 417 pass/1 skip
- **Review:** fresh-context APPROVE — label-only, dispatch unchanged
- **Run:** `.agent-loop/runs/20260701-092733-bak-131-approve-labels/`
- **What landed:** rec-detail primary "Approve" → "Approve & run"; "& schedule" variant is the existing Schedule button.
- **Revert:** `git revert cd485be9409c879036e5d2b9459b698cca5f0965`


## 2026-07-01 — MERGED · BAK-130 agent console header subhead (PR)
- **Risk:** low (Improvement; AgentConsoleView header) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 417 pass/1 skip
- **Review:** fresh-context APPROVE — VStack-wrap balanced, agent.isSweeping valid, Theme tokens, no logic change
- **Run:** `.agent-loop/runs/20260701-092456-bak-130-subhead/`
- **What landed:** dynamic subhead under "Agent" ("reviewing your sources…"/"plans your day with you") + kept progress/toggle ("both").
- **Revert:** `git revert 59e1ca1d25326bb861b8d6fda1619491eebb03e3`


## 2026-07-01 — MERGED · BAK-132 Trust segmented control (PR)
- **Risk:** medium (Improvement; AgentConsoleView view-only — NOT TrustPolicy) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 417 pass/1 skip
- **Review:** fresh-context APPROVE — selection set closure byte-for-byte same dispatch (trustRaw + agent.applyTrust); no gating path touched (TrustPolicy/RecommendationAction diff empty); binding sound, no loop; Theme.agent tint
- **Run:** `.agent-loop/runs/20260701-092220-bak-132-trust-seg/`
- **What landed:** Trust dropdown Menu → `.segmented` Picker (active=purple); per-item blurb necessarily dropped (segmented has no subtitle) but the always-visible blurb card from BAK-112 covers it.
- **Revert:** `git revert afa6da4f251c480adb33fb6e2a2a34ad6e41730a`


## 2026-07-01 — MERGED · BAK-135 board drag-over column highlight (PR)
- **Risk:** low (Improvement; BoardView only) · **Deep-review:** n/a
- **Checks:** swift build clean · swift test 417 pass/1 skip
- **Review:** fresh-context APPROVE — isTargeted enter/leave guard avoids stuck dual-highlight; overlay scoped to full column (collapsed strips unaffected); drop handler unchanged; Theme.accent
- **Run:** `.agent-loop/runs/20260701-091958-bak-135-drag-highlight/`
- **What landed:** `.dropDestination(isTargeted:)` + `dropTargetStage` @State → 2px accent outline on the targeted column.
- **Revert:** `git revert 87c28f6fb5471834644efa6ed1345ab578e621a1`


## 2026-07-01 — MERGED · BAK-118 parity audit: detail + create/edit form (PR #52)
- **Risk:** medium (Improvement; TaskDetailSheet view edits + docs) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 417 pass/1 skip · CI (self-hosted)
- **Review:** fresh-context APPROVE — interactive subtasks toggle/remove correct + delete-safe (.nullify), progress recomputes, no ForEach-mutation reentrancy; assignee accent cosmetic; create/edit form strong parity
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-085104-bak-118-parity-detail/`
- **What landed:** docs/design/redesign-2026/parity/detail-form.md; inline fixes — interactive subtasks (toggle done + remove), assignee accent purple for agent. Follow-ups: BAK-136 (stage-adaptive footer matrix), BAK-137 (read-mode approval view).
- **Milestone:** completes the desktop-delta *audits*. Desktop redesign delta done except the spun-out polish follow-ups (BAK-130/131/132/133/134/135/136/137) + reused BAK-49/51.
- **Revert:** `git revert edaf153bde5c008505249ca180344363b8bbb7db`

## 2026-07-01 — MERGED · BAK-117 parity audit: Board + card (PR #51)
- **Risk:** medium (Improvement; cosmetic card/board views + docs) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 417 pass/1 skip · CI (self-hosted)
- **Review:** fresh-context APPROVE — presentation-only, no logic change; overdue branch sound, tag chips + hover-toggle correct (agent still shown via left accent), "All" label display-only; strong parity post-polish, no regressions
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-084538-bak-117-parity-board/`
- **What landed:** docs/design/redesign-2026/parity/board.md; inline fixes — overdue due red/amber+bold, tags as pill chips, owner toggle hover-revealed, "All areas"→"All". Follow-ups: BAK-134 (+New task + Search), BAK-135 (drag-over highlight).
- **Revert:** `git revert d47de79a375c237b379f11a017069ca51f7bbc0c`

## 2026-07-01 — MERGED · BAK-112 parity audit: Settings + Trust (PR #50)
- **Risk:** HIGH (path: TrustPolicy.swift) · **Deep-review:** PASS (3/3 clear — correctness, security/risk, spec)
- **Checks:** swift build clean · swift test 417 pass/1 skip · CI (self-hosted)
- **Deep-review:** copy-only change confirmed (gating predicates byte-for-byte unchanged; `blurb` is display-only); new blurb safety claims verified TRUE vs `isGated` model; all 5 strings byte-for-byte verbatim to the prototype. Report: deep-review-report.md.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-083833-bak-112-parity-settings/`
- **What landed:** TrustPolicy.blurb aligned to handoff copy verbatim; always-visible trust blurb + gated footer note in the console; parity report. Follow-ups: BAK-132 (trust segmented control), BAK-133 (standalone Settings screen + per-source Connected).
- **Note:** HIGH was purely the path trigger; actual change is display copy. Honoured the panel anyway.
- **For Leon's eye:** trust blurb + gated footer note in the console.
- **Revert:** `git revert 9b6c02ee42c5dcab59fccbdc5f1b1bf43abcc903`

## 2026-07-01 — MERGED · BAK-111 parity audit: Agent console (PR #49)
- **Risk:** medium (Improvement; cosmetic views + docs) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 417 pass/1 skip · CI (self-hosted)
- **Review:** fresh-context APPROVE — presentation-only (✦ Sweep + action pill, WHY header, gated full-width banner), gated banner still `isGated`-gated, title HStack intact, Theme tokens, no logic change; parity report + ADR-0010 PRD note accurate
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-083219-bak-111-parity-console/`
- **What landed:** docs/design/redesign-2026/parity/agent-console.md (mostly MATCH); inline console parity fixes; PRD stale-spec note (console Review queue is board-side per ADR-0010). Follow-ups filed: BAK-130 (header subhead), BAK-131 (contextual approve labels).
- **Revert:** `git revert d3c4912bee8c8f0768d5446a6b12c7587b5f8dd8`

## 2026-07-01 — MERGED · BAK-107 blockedByTask dependency (PR #48)
- **Risk:** medium (Feature; additive SwiftData relationship + detail/form) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 417 pass/1 skip (+4 BlockedByTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — additive optional relationship is lightweight-migration-safe (existing stores decode nil; container model list unchanged), third self-ref unambiguous (no inverse), isBlocked non-recursive, .nullify delete-safe, cycle can't hang
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-082656-bak-107-blockedby/`
- **What landed:** `MustardTask.blockedByTask` (`@Relationship(.nullify)`, optional, CloudKit-safe); isBlocked derives from an unfinished blocker (free-text path kept); `BlockedByPicker` + "Blocked by" row in the detail/create-edit form (search, excludes self+done).
- **For Leon's eye:** Blocked-by picker + blocked treatment on the board.
- **Revert:** `git revert 63203df21edc9103a778278603ddd5672d5815e8`

## 2026-07-01 — MERGED · BAK-106 agent co-pilot dock (PR #47)
- **Risk:** medium (Feature; AgentInbox helpers + RootView) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 413 pass/1 skip (+4 dockText tests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — dockText pluralization/empty/joiner correct + tested, counts consistent with sidebar badge by construction (same helpers), dock hidden on .agent (no loop), layout sound (sibling in VStack, fills height)
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-082308-bak-106-dock/`
- **What landed:** `AgentInbox.pendingRecCount/outputCount/dockText`; RootView persistent bottom co-pilot dock (purple dot + Agent + derived text + "Open console →") on every screen except the Agent console. (Prototype surface not in the README.)
- **For Leon's eye:** dock bar placement + Open console link.
- **Revert:** `git revert 00979c1d9772ea1bc77b86901bf8a4e395280ac8`

## 2026-07-01 — MERGED · BAK-109 Week ✦ Balance + Undo (PR #46)
- **Risk:** medium (Feature; WeekPlanner algorithm + WeekView) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 409 pass/1 skip (+6 WeekBalanceTests) · CI (self-hosted)
- **Review:** round 1 CHANGES-REQUESTED — greedy LPT could land on a peak ≥ input while toast claimed success (reviewer fuzz-found). **Fixed:** no-regression guard (commit only if newPeak < currentPeak; else "already balanced") + regression test ({30,30}|{20,20,20} → LPT would hit 70, guard holds 60). Round 2 APPROVE — guard apples-to-apples, no new edge bugs, regression test genuine.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-081411-bak-109-balance/`
- **What landed:** `WeekPlanner.balance(_:weekdays:)` (LPT + no-regression guard, BalancePlan/BalanceMove with prior date for exact Undo, excludes done/meetings, preserves time-of-day); WeekView "✦ Balance" button + dark toast + Undo (auto-dismiss 6s).
- **Known non-blocking:** when the heuristic can't improve an imbalanced layout it still says "already balanced" (cosmetic wording).
- **For Leon's eye:** Balance button + toast + Undo restore.
- **Revert:** `git revert 2f20549208e43dbda7e3f7f254d8dec35af75cdb`

## 2026-07-01 — MERGED · BAK-105 Week capacity + load bar + time-of-day grouping (PR #45)
- **Risk:** medium (Feature; WeekPlanner logic + WeekView) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 403 pass/1 skip (+5 WeekCapacityTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — tier boundaries (360/480) + label + timeOfDay + grouping all tested; capacityMinutes clock-independent (no done/double-count); Theme bar colours match handoff; ForEach id:\.0 safe
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-080709-bak-105-week-capacity/`
- **What landed:** `WeekPlanner.capacityMinutes/loadTier/capacityLabel/timeOfDay/groupByTimeOfDay`; WeekView day header capacity label (tier-coloured) + load bar; non-axis tasks grouped Morning/Afternoon/Evening/Anytime. Shared logic mobile Week (BAK-116) reuses.
- **Known non-blocking:** header capacity counts open tasks incl. agent-owned + a past-day-vs-column edge (spec says "open tasks"); String(format) locale separator (en-only app).
- **Unblocks:** BAK-109 (Week ✦ Balance).
- **For Leon's eye:** load bar colours + time-of-day section headers.
- **Revert:** `git revert 05f79d3a68807b7ba8b9dfae0acfe43651eb6cbd`

## 2026-07-01 — MERGED · BAK-104 Today dismissible agent nudge (PR #44)
- **Risk:** medium (Feature; shared Logic helper + TodayView + RootView) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 398 pass/1 skip (+3 AgentInboxTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — no ✕/card double-fire (Button wins hit-test), helper composes RecommendationQueue.pending + needsReview, RootView badge refactor makes it consistent with NotchSurface/HoverPanel (which already used the pending formula), pluralization + auto-hide correct
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-080209-bak-104-nudge/`
- **What landed:** `AgentInbox.waitingCount(recommendations:tasks:now:)`; TodayView dismissible "Agent has N things for you" nudge (tap→console, ✕ dismiss, auto-hide at 0); RootView waitingCount now shares the helper (snooze/ignore-aware).
- **Known non-blocking:** dismiss is session-scoped (won't reappear on new items same session); NotchSurface/HoverPanel still inline the same formula (future cleanup to route through AgentInbox).
- **Revert:** `git revert 8a19dbb5914d43fd53718066e1e33dc58ef36ff7`

## 2026-07-01 — MERGED · BAK-103 Today day-progress bar + Plan entry (PR #43)
- **Risk:** medium (Feature; DayPlanner helper + TodayView + RootView) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 395 pass/1 skip (+2 DayProgressTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — progress derivation correct (done in total, not pinned 100%), bar gated by total>0 (no NaN), onPlan default keeps preview safe, all 3 TodayView call sites compile, Theme tokens only
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-075733-bak-103-today/`
- **What landed:** `DayPlanner.dayProgress(_:day:)`; TodayView day-progress bar ("N of M done") + "✦ Plan with agent" header button (onPlan → RootView screen=.agent). Quick-add already existed (QuickCaptureField).
- **For Leon's eye:** progress bar fill + Plan button navigation.
- **Revert:** `git revert b5f45a52ecbbc3e76ac930e2e944d11289918ebd`

## 2026-07-01 — MERGED · BAK-102 board auto-collapse empty columns (PR #42)
- **Risk:** medium (Improvement; BoardView + PersonalBoard helper) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 393 pass/1 skip (+5 collapse-rule tests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — collapse predicate pure + all-branch tested, done "+N older" tail handled, no stuck/duplicate-key state, QuickColumnAdd not duplicated
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-075244-bak-102-column-polish/`
- **What landed:** `PersonalBoard.shouldCollapseEmpty(...)`; BoardView collapses empty columns to tap-to-expand strips (Everyone lens only, not Mine/Agent/review-focus); empty columns read "Drop here". Per-column "+ Add" was already QuickColumnAdd.
- **Known non-blocking:** a collapsed strip isn't a drop target (must click-to-expand first) — matches spec.
- **For Leon's eye:** strip appearance + click-to-expand.
- **Revert:** `git revert 1c73feb5f34defb357b78df4db17366e4ecc2785`

## 2026-07-01 — MERGED · BAK-101 board review-focus mode + caption (PR #41)
- **Risk:** medium (Feature; BoardView + PersonalBoard constant) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 388 pass/1 skip (+1 BoardFocusTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — toggle correct, columns pin to gateStages when focused, pill stays visible at count 0 (always an exit), count derived + owner/area-scoped, focus orthogonal to owner/area (no stuck state); removed 2 hardcoded hexes
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-074835-bak-101-review-focus/`
- **What landed:** header waiting pill → toggle button; review-focus collapses board to `PersonalBoard.gateStages` ([needsApproval, needsReview]); pill flips to "Exit review queue" (filled); focus-aware caption.
- **For Leon's eye:** collapse/restore + filled-pill state.
- **Revert:** `git revert 15c93d9297dedd4a82e18862c02be57aa5130318`

## 2026-07-01 — MERGED · BAK-100 board inline gate actions + reverse transitions (PR #40)
- **Risk:** medium (Feature; Logic helper + 2 views) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 387 pass/1 skip (+5 GateTransitionTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — state machine reused (not forked), gated/non-gated branch correct, labels exact, no tap double-fire (Button beats ancestor onTapGesture), delete is .nullify-safe (subtasks/delegation), reverse transitions stage-gated
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-074219-bak-100-gate-actions/`
- **What landed:** `PersonalBoard.approveTarget(for:)` (needsApproval→queued if gated else needsReview; needsReview→done); MustardBoardCard hover gate actions (✓ Approve & run / ✓ Approve / ✓ Accept + Deny/Discard-deletes); TaskDetailSheet Hold (queued→needsApproval) + Request changes (needsReview→queued).
- **For Leon's eye:** confirm hover reveal + that tapping the buttons doesn't also open the detail panel.
- **Revert:** `git revert 56b05ecbac91eeb96d966dc4799312244af3d06f`

## 2026-07-01 — MERGED · BAK-99 board card priority flag + Proposed pill + tags (PR #39)
- **Risk:** medium (Feature; Sources/ — additive model + view) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 382 pass/1 skip (+5 BoardCardMetaTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — enum reorder rawValue-stable (no migration), only exhaustive switch still exhaustive, no order-dependent consumers; flag hex matches handoff; isProposed + done-card gating correct
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-073543-bak-99-card-meta/`
- **What landed:** `TaskPriority.urgent` (reordered Low→Urgent, stable rawValues) + derived `MustardTask.isProposed` (agent+inbox); MustardBoardCard top-row priority flag (HIGH/URGENT) + ✦ Proposed pill + tags row (#tag, max 3), all Theme tokens. Create/edit Priority picker auto-gains Urgent via allCases.
- **For Leon's eye:** confirm HIGH/URGENT pill + Proposed pill + tags read well on a dense card.
- **Revert:** `git revert 85d9ec477de0938e7b329ecfcb66b2206ad5f922`

## 2026-07-01 — MERGED · BAK-98 design-token consolidation + confidence colour (PR #38)
- **Risk:** medium (Improvement; `Sources/` — Theme + 4 views + seed; no auth/trust/ClaudeRunner) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 377 pass/1 skip (+3 ThemeTests) · CI (self-hosted)
- **Review:** fresh-context APPROVE — render-identity verified hex-by-hex (every migrated token == original literal), drift fix matches README canonical, source-badge map reproduces handoff, ThemeTests pin thresholds
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-071051-bak-98-tokens/`
- **What landed:** `Theme` is now the canonical handoff token home (surfaces, agent tints, done/review, warn, status, confidence, priority, area dots); single `Theme.confidenceColor` (≥0.7/≥0.5) + `confidenceTier`; centralised `Theme.sourceBadge`. MustardBoardCard + BoardView.ColumnStyle inline hex → tokens (renders identically). Drift fix: RecommendationDetailView + AgentConsoleView dropped their ≥0.4 amber cutoff (0.40–0.49 now red). Seed Admin dot green #3E8E7E.
- **Behaviour change:** confidence 0.40–0.49 shifts amber→red in rec-detail + console (intended). Preview-only: a seeded gmail-source card now shows the Gmail badge (was KB grey) — toward spec.
- **Deferred:** exact handoff per-list dot colours under one group header need a per-list `TaskList.colorHex` (model change) — documented in the PRD, not done here.
- **For Leon's eye:** confirm board/console look unchanged + the gmail preview card badge reads right.
- **Revert:** `git revert 501e8d6284faad64693b9acb406f822d1ca6784e`

## 2026-07-01 — MERGED · BAK-97 vendor 2026 redesign handoff + PRD (PR #37)
- **Risk:** low (docs-only; `docs/design/redesign-2026/**` + run artifacts; no Sources/Package/config) · **Deep-review:** n/a (low auto-merges after fresh-context review)
- **Checks:** swift build clean · swift test 366 pass/1 skip (baseline; no behaviour changed) · CI (self-hosted)
- **Review:** fresh-context APPROVE; one non-blocking nit (PRD threshold recommendation mislabelled the ≥0.5 set as "desktop code") fixed before merge
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260701-061603-bak-97-vendor-handoff/`
- **What landed:** vendored desktop+mobile prototypes + handoff README into `docs/design/redesign-2026/` (excludes prototype runtime support.js/ios-frame.jsx) and a `PRD.md` mapping the handoff to the BAK-97..119 task graph; documents two parity discrepancies (confidence thresholds; Admin dot colour) for BAK-98.
- **Kickoff context:** first slice of the 2026 redesign. Most of the desktop is already shipped — remaining work is the desktop delta (BAK-98..107, parity audits 111/112/117/118) + the iOS companion (foundation BAK-108, blocked on Apple Dev entitlements → shell 110 → screens 113/114/115/116/119).
- **Revert:** `git revert 0aa29e7fbd7b161e31dcf49dfd7345bbdc07a3e7`

## 2026-06-30 — MERGED · BAK-84 quarantine undecodable agent result files (PR #36)
- **Risk:** medium (Improvement; Logic + BridgeIO + a one-line `ingestAgentResults` call) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 366 pass/1 skip (+5 tests) · swift build clean · CI (self-hosted) green 43s
- **Review:** fresh-context no blockers; keep-criterion parity confirmed exact; Part-1 obsolescence independently verified; rerun-idempotency test folded in (45ba930)
- **Outward actions:** none · quarantine relocates a local file Mustard already ignores
- **Run:** `.agent-loop/runs/20260630-203248-bak84-bridge-routing/`
- **What landed (Part 2):** `BridgeIO.quarantineUndecodableResults` moves undecodable/empty-uid `results/*.json` → `results/quarantine/` (same keep-criterion as readResults); `ingestAgentResults` calls it each run after archiving the good ones; `BridgeFolders.resultsQuarantine`.
- **Part 1 (route via AreaRouter) — OBSOLETE:** BAK-87 already reworked routing (loop uses each SourceConfig's `workingDirectory` + `AreaMapping`, never `defaultAreaMap`); `AreaRouter` is dead. Documented + stale comment refreshed; dead-AreaRouter removal filed as **BAK-96**.
- **Process note:** built in an isolated git worktree off `origin/main` (per the BAK-90 concurrency lesson).
- **Revert:** `git revert f911b85dfdf8ade62f3e452930bf4af7c5d155cb`

## 2026-06-30 — MERGED · BAK-91 capture + surface referenced Shortcut/Jira link (PR #35)
- **Risk:** medium (Feature; new Logic helper + a 2-line `materializeTask` change + a View; the AgentService touch carries no dispatch/gating logic) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 361 pass/1 skip (+9 tests) · swift build clean · CI (self-hosted) green 44s
- **Review:** fresh-context no blockers; its one finding (host-substring label false positives) fixed in commit a07e461 + regression tests
- **Outward actions:** none · reads/parses text + stamps fields on a new inbox task
- **Run:** `.agent-loop/runs/20260630-201835-bak91-task-links/`
- **What landed:** pure `TaskLinkExtractor` (NSDataDetector → Shortcut/Jira/host labels, host-boundary match, dedupe); `materializeTask` carries `rec.sourceURL` + `task.links`; `TaskDetailSheet` Links section (show/open/remove/add).
- **Process note:** built in an ISOLATED git worktree off `origin/main` (per the BAK-90 concurrency lesson) — no shared-HEAD collision this time.
- **Leon — visual confirm pending:** Links section shows/opens carried links; manual add works (UI build-verified only).
- **Revert:** `git revert 52a89e7669273c87f581f37dc1b6f3b7fc5e24fb`

## 2026-06-30 — MERGED · BAK-90 require a client area before agent hand-off (PR #33)
- **Risk:** high (escalated — touches `AgentService.delegate`, the agent hand-off control path) · **Deep-review:** PASS (3/3 — correctness + security/risk + spec-faithfulness, all clear)
- **Checks:** swift test 352 pass/1 skip (+4 tests) · swift build clean · CI (self-hosted) green 47s
- **Review:** fresh-context NON-BLOCKING (mergeable); panel 3/3 clear
- **Outward actions:** none · the change BLOCKS a hand-off; performs no send/deploy/delete
- **Run:** `.agent-loop/runs/20260630-195959-bak90-require-area/` (artifacts stranded on the `leon/bak-82` branch — see note below)
- **What landed:** pure `PersonalBoard.canHandOffToAgent` (area required); `AgentService.delegate` guards on it (chokepoint for all 4 "Ask agent" buttons) + `lastHint`/`clearHint`; BoardView drop-handler guard + amber hint banner.
- **Follow-up filed:** BAK-95 — TaskDetailSheet Stage/Assignee pickers still bypass the gate (benign; export filters by area regardless).
- **⚠️ Concurrency note:** this run collided with a parallel dev-loop session building BAK-82 in the SAME working tree — that session checked out `leon/bak-82` off this branch's tip, so the BAK-90 run-artifacts commit (5cdc3fe) and this entry's source landed via an isolated worktree. PR #33 itself was clean (single BAK-90 commit). Recommend per-session git worktrees/clones to prevent shared-HEAD stomping.
- **Revert:** `git revert 7d4282d1ee1915824818ac0bedb189ddd6e3dba0`

## 2026-06-30 — MERGED · BAK-89 settable task actionType + export guard (PR #32)
- **Risk:** medium (Feature; Logic + Views; no high path, no AgentService change) · **Deep-review:** n/a (medium auto-merges after fresh-context review)
- **Checks:** swift test 348 pass/1 skip (+3 tests) · swift build clean · CI (self-hosted) green 42s
- **Review:** fresh-context APPROVE, no blockers (one follow-up test folded in)
- **Outward actions:** none · the change makes export STRICTER + adds UI
- **Run:** `.agent-loop/runs/20260630-195145-bak89-actiontype/`
- **What landed:** `BridgeExport.plan` skips a `.queued` task with no actionType (would emit an empty-action execute order; forAgent/prep exempt); `TaskDetailSheet` Action picker; `MustardBoardCard` amber "Needs an action type" pill.
- **Leon — visual confirm pending:** Action picker persists; queued card flips amber→"Queued to run" once an action is set (UI build-verified only).
- **Revert:** `git revert da775334b011147adca8cd06dd6e49b5e049ee40`

## 2026-06-30 — MERGED · BAK-92 bridge double-execution race fix (PR #31)
- **Risk:** high (escalated — agent work-dispatch correctness path; no high path literally matched) · **Deep-review:** PASS (3/3 — correctness + security/risk + spec-faithfulness, all clear, no fix round)
- **Checks:** swift test 345 pass/1 skip (+6 tests) · swift build clean · CI (self-hosted) green 42s
- **Outward actions:** none · the diff is pure logic + a non-mutating dir read; it makes dispatch strictly *more* conservative
- **Run:** `.agent-loop/runs/20260630-191727-bak92-bridge-double-exec/`
- **Root cause:** between the worker archiving a consumed outbox order + writing a result and Mustard's next ingest tick, the task stays `.queued`/`.forAgent` with no live outbox file → `BridgeExport.plan` re-issued the order → a worker on the duplicate executes twice (e.g. a second Gmail draft / Shortcut story).
- **Fix:** `plan` gains a `liveResultUIDs` guard — suppress a re-write when a LIVE `results/<uid>.json` exists (NOT `results/done/`, so the `failed`-retry path still re-issues). New `BridgeIO.liveResultUIDs` (non-recursive). Loop ordering (export→ingest) documented as load-bearing.
- **Follow-ups (non-blocking, panel-raised):** fail-open hardening of `liveResultUIDs` (distinguish absent dir vs listing error); worker-side idempotency backstop (Phase 3); true exactly-once via atomic outbox claim.
- **Revert:** `git revert 6ca9bd05c647f4089d59125bf12b76703dc926f3`

## 2026-06-29 — MERGED · BAK-87 project→area routing fix (PR #29)
- **Risk:** high (AgentService) · **Deep-review:** PASS (2-lens — correctness + security/scope, both clear; small focused fix)
- **Checks:** swift test 339 pass/1 skip · swift build clean
- **Root cause:** `project` stored as folder name ("DL-Knowledge-Base") but area maps code-keyed ("DL") → bridge export was DORMANT in real config + promote stamped no area → triage-approved recs never reached the outbox.
- **Fix:** `AreaMapping.areaName(forProject:)` (folder-name + code → area); bridge loop uses it; promote/materializeTask stamp the task's area (find-or-create). `AreaRouter` now dead code.
- **Revert:** `git revert 12540b9739eabde787921fb07b867c4b93df94c7`

## 2026-06-29 — MERGED · BAK-83 Agent Bridge Phase 2 (PR #27)
- **Risk:** high (touches AgentService) · **Deep-review:** PASS (3/3 clear, no fix round)
- **Checks:** swift test 334 pass/1 skip · swift build clean · CI (self-hosted)
- **Outward actions:** none · bridge is file I/O only (no execution/send); staging-only
- **Run:** `.agent-loop/runs/20260629-agent-bridge-phase2/`
- **What landed:** AgentWorkOrder/AgentResult schemas, pure BridgeExport/BridgeIngest, FileBridgeIO, AgentService export+ingest on the 10-min loop, file-contract doc
- **Follow-ups:** route via AreaRouter (vs defaultAreaMap); archive undecodable result files; (BAK-82 meeting titles, separate)
- **Deferred:** Phase 3 — the connected-session worker that drains outbox, runs dl-create-shortcut-story, writes results
- **Revert:** `git revert fe3b5b1b08e02475d9f23bc9215caca82ecc1e99`

## 2026-06-29 — MERGED · BAK-73 Agent Task Board Phase 1 (PR #26)
- **Risk:** high (agent core — AgentService rewired) · **Deep-review:** PASS (3/3 clear after 1 fix round)
- **Checks:** swift test 315 pass/1 skip · swift build clean · CI (self-hosted)
- **Outward actions:** none · Phase 1 is staging-only (no executor drains `.queued`)
- **Run:** `.agent-loop/runs/20260629-board-phase1/`
- **What landed:** `TaskStage` model + migration, owner-segmented board UI, rec→board promotion, OutputCard/DelegationPhase retired, ADR-0010
- **Follow-ups:** BAK-82 (meeting task titles); VersionedSchema hardening; minor board UI tweaks (Leon)
- **Deferred:** Phase 2 (vault-file bridge) + Phase 3 (connected-session worker) — each gets its own spec
- **Revert:** `git revert 9ad0f2896d5a32bcc0bb8412d74bb1201081c454`

## 2026-06-29 — MERGED · BAK-45 Live Google Calendar connect (PR #25)
- **Risk:** high (OAuth/auth + Keychain) · **Deep-review:** PASS (3/3 clear after 1 fix round)
- **Checks:** swift test 323 pass/1 skip · swift build clean · CI (self-hosted) green
- **Outward actions:** none · client secret user-entered, Keychain-only
- **Run:** `.agent-loop/runs/20260629-103052-bak45-gcal-connect/`
- **Remaining:** manual live connect test (Task 10, Leon) — paste Desktop client id+secret in Settings → Connect
- **Follow-ups:** BAK-71 (Theme error token, test stub dedup, window edge)
- **Revert:** `git revert e7675bd7da0536f1dcc263ebe19eb8e87c6c8b65`

## 2026-07-10 — MERGED · hotfix: duplicate Theme.Motion enum (PR #85)
- **Risk:** low–medium (design tokens; Sources/) · **Auto-merged** (no deep-review needed)
- **Checks:** swift build clean · swift test 686 pass/1 skip/0 fail
- **Why:** main did not compile — PR #83 left a 2nd `Theme.Motion` enum beside PR #78's (CI runner was down, so no build gate caught it). Blocked all ticket work.
- **What landed:** merged both enums into one canonical Motion (easeOut/easeInOut/drag/settle/expand/pop); `settle` = snappy(0.16) from #83's set. No call-site changes.
- **Outward actions:** none
- **Prerequisite for:** BAK-246/247/245/244 (Linear kickoff pickup)
- **Revert:** `git revert d38c95054ab62f0fddf2e09eacb5c311ad0e8e57`

## 2026-07-10 — MERGED · BAK-246 Scheduled tasks stuck in Inbox (PR #86)
- **Risk:** medium (Logic/Views + idempotent store migration) · **Auto-merged** (no deep-review)
- **Checks:** swift build clean · swift test 692 pass/1 skip/0 fail
- **Fresh-context review:** PASS (standards/spec/risk/tests; all scheduledAt write sites traced)
- **What landed:** `PersonalBoard.normalizePlacement` invariant helper (scheduled ⇒ never .inbox; timed→.scheduled else .planned), called at every scheduledAt write site (desktop+iOS), + `BoardMigration.normalizeScheduledPlacement` one-time launch repair. 6 new tests.
- **Outward actions:** none
- **iOS:** build-ios.sh not run in-session (no toolchain); mobile change mirrors desktop, Leon eye-check pending
- **Run:** `.agent-loop/runs/20260710-200334-bak-246-inbox-placement/`
- **Revert:** `git revert ce72ce24546520c80862a1a66f748e0ddae9e6b7`

## 2026-07-10 — MERGED · BAK-247 FOCUS pins duplicating in timeline (PR #87)
- **Risk:** medium (Logic/Views display filter) · **Auto-merged** (no deep-review)
- **Checks:** swift build clean · swift test 696 pass/1 skip/0 fail
- **Fresh-context review:** PASS (mobile "no FOCUS section" claim independently verified)
- **What landed:** `RitualPlanner.timeline` = tasksForDay minus focus-starred-today; TodayView filters the timeline + empty-state guards FOCUS. Display dedup (confirmed not a data dup). 4 new tests.
- **Mobile:** unchanged — MobileTodayView has no FOCUS section, so no dup; filtering would regress.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260710-202258-bak-247-planner-dup/`
- **Revert:** `git revert 470e9859b1f70c5f2c1617724bafa578c22d28ec`

## 2026-07-10 — MERGED · BAK-245 TimelineRow condensed detail-card styling (PR #88)
- **Risk:** medium (view restyle) · **Auto-merged** (no deep-review)
- **Checks:** swift build clean · swift test 696 pass/1 skip/0 fail
- **Fresh-context review:** PASS (token/vocab reuse verified; Week/WeekBlock + iOS-mirror claims verified; 4 non-blocking nits all fixed)
- **What landed:** shared public chip vocabulary (TaskChips.swift: TaskRowDensity/PriorityFlag/MetaChip/TaskChipRow); TimelineRow → checkbox+bold title+inline flag+chip strip, gutter dropped; board card adopts shared PriorityFlag; iOS Today row mirrored; ListBadge removed.
- **⚠ Leon eye-check PENDING (desktop + iOS) — iOS not built by swift build (needs build-ios.sh/xcodegen).**
- **Outward actions:** none
- **Run:** `.agent-loop/runs/*bak-245-timelinerow/`
- **Revert:** `git revert e4648e8c8094ebe24818fb71193697be77e08d1a`

## 2026-07-10 — MERGED · BAK-244 Opened-task detail design pass (PR #89)
- **Risk:** medium (view restyle) · **Auto-merged** (no deep-review)
- **Decision:** Leon chose live-edit-restyled (not read-first) during brainstorm; approved the mockup.
- **Checks:** swift build clean · swift test 696 pass/1 skip/0 fail
- **Fresh-context review:** PASS (live-edit fully preserved — all 14 controls + title binding intact; field helper unused; gating logic untouched)
- **What landed:** TaskDetailSheet new header (stage badge+owner, editable docH1 title+inline flag, shared TaskChipRow) + calm hairline sections replacing grey cards; agentContext + BAK-136 footer kept; iOS MobileTaskSheet header mirrored.
- **⚠ Leon eye-check PENDING (desktop + iOS) — iOS not built by swift build.**
- **Outward actions:** none
- **Run:** `.agent-loop/runs/*bak-244-task-detail/`
- **Revert:** `git revert ac2b2964a67f1af60989555f45006281de47fd35`

## 2026-07-11 — MERGED · Task detail right-side drawer (PR #90)
- **Risk:** medium (view presentation) · **Auto-merged** (no deep-review)
- **Origin:** Leon request during BAK-244 eye-check; docked style eye-confirmed in the running app.
- **Checks:** swift build clean · swift test 696 pass/1 skip/0 fail
- **Fresh-context review:** PASS (all close paths via close(); all 5 sheet sites converted; no surface missed)
- **What landed:** reusable `.taskDetailDrawer(item:)` docks TaskDetailSheet on the trailing edge (reflow, full height, expand-motion slide, .id per task); TaskDetailSheet gained onClose + fills height; Today/Week/Board/Lists/notch swapped from .sheet.
- **Desktop only;** iOS MobileTaskSheet keeps its bottom sheet.
- **Note:** in-screen drawers now route SourceLinkButton to the source inspector (intended).
- **Outward actions:** none
- **Run:** `.agent-loop/runs/*task-detail-drawer/`
- **Revert:** `git revert cd049eece8bd869e710b2b3502963a277dd23e50`

## 2026-07-12 — MERGED · Craft editor Phase 0: shared BlockKind model (PR #91, BAK-249)
- **Risk:** medium (Logic/+Tests/+docs only) · **Auto-merged** (no deep-review)
- **Origin:** Leon brainstorm 2026-07-12 (four Craft/Tolaria screenshots) → spec `docs/specs/2026-07-12-craft-editor-menus-design.md` + epic BAK-248 (F23); this is sub-issue BAK-249.
- **Checks:** swift build clean · swift test 717 pass/1 skip/0 fail (baseline 696 + 21 new BlockKindTests)
- **Fresh-context review:** APPROVE, 0 blocking (additive-only confirmed; round-trip clause legitimately deferred to BAK-251/252; no premature consumers)
- **What landed:** canonical `BlockKind` enum + additive `NoteDecoration.blockKind(_:of:)` classifier; new table/image/todo-vs-bullet classification (classification only, no rendering change); spec + F23 build-order entry ride along.
- **⚠ Leon note:** heading levels 5-6 classify unclamped (spec's "1...4" read as the Phase-2 insert-menu range, not a classification cap — rationale in `BlockKind.swift`). Flag if you disagree.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260712-150000-bak249-blockkind/`
- **Revert:** `git revert 5afbeca`

## 2026-07-12 — MERGED · Craft editor Phase 1: fully-hidden markdown (PR #92, BAK-250)
- **Risk:** medium (Logic/+Views/+Tests) · **Auto-merged** (no deep-review)
- **Origin:** epic BAK-248 (spec `docs/specs/2026-07-12-craft-editor-menus-design.md`), flagged there as the epic's highest technical risk (NSTextView).
- **Checks:** swift build clean · ./build-app.sh assembles · swift test 728 pass/1 skip/0 fail (baseline 717 + 11 new)
- **Fresh-context review:** APPROVE-WITH-FOLLOW-UPS, 0 blocking. Finding 1 (stale-baseline selection guard) fixed inline on the PR; findings 2-3 → BAK-254.
- **What landed:** pure `NoteDecoration.markerVisibility` focus-aware decision layer + TextKit-1 `setNotShownAttribute` glyph-flag hiding in MarkdownTextView — heading/quote/emphasis/inline-code markers hide when the block is unfocused, reveal on cursor-enter; text storage and `.md` on disk never change. Bullets/fences/rules/wikilink brackets deliberately stay visible (documented); checkbox brackets deferred (BAK-254).
- **⚠ Leon eye-check PENDING:** hide/reveal feel, caret stability, cmd-tab-away behavior (may leave focused block's markers revealed — BAK-254 note), pills/cards/slash-menu/drag-reorder unaffected.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260712-153000-bak250-hidden-markdown/`
- **Revert:** `git revert 8be3adc`

## 2026-07-12 — MERGED · Craft editor Phase 2: expanded insert menu (PR #93, BAK-251)
- **Risk:** medium (Logic/+Views/+Tests) · **Auto-merged** (no deep-review)
- **Origin:** epic BAK-248 (spec `docs/specs/2026-07-12-craft-editor-menus-design.md`).
- **Checks:** swift build clean · ./build-app.sh assembles · swift test 747 pass/1 skip/0 fail (baseline 728; SlashMenuTests 14→33)
- **Fresh-context review:** APPROVE-WITH-FOLLOW-UPS, 0 blocking; reviewer verified the SlashMenuTests rewrite test-by-test (strengthening only, byte-exact original templates). Sole finding (highlight scrolls off-screen) fixed inline.
- **What landed:** slash menu 5→16 grouped commands (Headings H1-4 / Basic blocks Quote·Bullet·Numbered·Check·Paragraph·Code·Divider / Advanced Table·Link·Sub-page·Ask-agent / Media Image syntax-only); grouped SlashMenuView with height cap + auto-scroll; round-trip guard on all new templates; MarkdownTextView keyboard code untouched. Table renders plain (full layout out of scope).
- **⚠ Leon eye-check PENDING:** grouped menu look, ↑/↓ + auto-scroll feel, table/image insertion carets.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260712-160000-bak251-insert-menu/`
- **Revert:** `git revert <squash-sha>` (see PR #93 merge commit on main)

## 2026-07-12 — MERGED · Craft editor Phase 3: Turn into + block actions (PR #94, BAK-252)
- **Risk:** medium (Logic/+Views/+Tests) · **Merged after review fix** (fresh-context review initially REQUEST-CHANGES)
- **Origin:** epic BAK-248 (spec `docs/specs/2026-07-12-craft-editor-menus-design.md`).
- **Checks:** swift build clean · ./build-app.sh assembles · swift test 798 pass/1 skip/0 fail (747 → 790 impl → 798 post-fix; BlockTransformTests 51)
- **Fresh-context review:** caught a real blocking bug — turn-into→Paragraph could silently reclassify (`# > note` → quote); fixed with per-line backslash escapes reusing NoteDecoration.classify; audit found+fixed a 2nd instance (table-cell ``` closing a code fence). Divider menu gating + frontmatter-adjacent tests also fixed. 0 remaining blockers.
- **What landed:** pure `BlockTransform` (turnInto/duplicate/delete/moveUp/moveDown, adversarial round-trip matrix), gutter ⠿ context menu (Turn into submenu + Actions, divider-gated), shared undo-safe `applyWholeDocumentSplice`, `MarkdownBlockRect.kind`.
- **⚠ Leon eye-check PENDING:** menu feel, one-step undo per action, caret placement, escaped-output readability.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260712-163000-bak252-turn-into/`
- **Revert:** `git revert 17d52e1`

## 2026-07-12 — MERGED · Craft editor Phase 4: inline formatting toolbar (PR #95, BAK-253) — EPIC BAK-248 COMPLETE
- **Risk:** medium (Logic/+Views/+Tests) · **Merged on green** (auto-merge arming disabled repo-side; merged post-CI)
- **Origin:** epic BAK-248 final phase (spec `docs/specs/2026-07-12-craft-editor-menus-design.md`).
- **Checks:** swift build clean · ./build-app.sh assembles · swift test 835 pass/1 skip/0 fail (798 + 37)
- **Fresh-context review:** APPROVE-WITH-FOLLOW-UPS, 0 blocking; findings (== prose false-positive, 2nd O(doc) scan per selection change, unwrap-test completeness) appended to BAK-254.
- **What landed:** floating selection toolbar (Bold/Italic/Strikethrough/Inline code/Highlight/Link) over pure `InlineFormat.toggle` with a re-parse wrap guard + involution tests; new `.strikethrough`/`.highlight` span kinds with Phase 1 hiding for free; undo-safe splice channel reused.
- **Epic BAK-248 (F23) now fully merged: PRs #91 #92 #93 #94 #95 · suite 696 → 835 · follow-ups consolidated in BAK-254.**
- **⚠ Leon eye-check PENDING (whole epic):** hidden-markdown feel + cmd-tab case · grouped slash menu + auto-scroll · turn-into/actions menu + one-step undo · toolbar toggles + link url-slot · escaped-output readability.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260712-170000-bak253-format-toolbar/`
- **Revert:** `git revert 1456f77`

## 2026-07-13 — MERGED · Craft editor eye-check fixes: working marker-hiding + block glyphs (PR #96)
- **Risk:** medium (Logic/+Views/+Tests) · **Merged on green** (post-CI)
- **Origin:** Leon's eye-check of the BAK-248 epic — markers weren't hiding in the running app, and checkboxes/bullets/dividers showed raw markdown.
- **Checks:** swift build clean · ./build-app.sh assembles · swift test 866 pass/1 skip/0 fail (baseline 840) · Leon eye-confirmed
- **Fresh-context review:** APPROVE, 0 blocking; below-last-line checkbox false-toggle fixed inline (fragment-rect guard + modifier-click exclusion).
- **What landed:** (1) marker hiding rewritten setNotShownAttribute → shouldGenerateGlyphs `.null` glyph property (real reflow + regeneration-safe; the old API never actually hid in-app); focus via FocusReportingTextView; "always hidden" policy (Leon). (2) block glyphs — clickable checkbox toggling [ ]↔[x], bullet dot, divider rule — drawn over transparent raw markdown via .mustardBlockGlyph + CardLayoutManager (text==source, no NSTextAttachment). Pure NoteDecoration.blockGlyph + CheckboxToggle, 26 tests.
- **Follow-ups (BAK-254):** per-keystroke full-doc marker rescan (bounded); blockquote still renders as plain text (no quote-bar yet); `* [X]` indented test gap.
- **Outward actions:** none
- **Run:** `.agent-loop/runs/20260713-bak254-craft-glyphs/`
- **Revert:** `git revert 26976fd`

## 2026-07-20 — MERGED · Resumable agent task sessions + file-backed drafts (F24) (PR #97)
- **Risk:** high (Agent/+Logic/+Models/+Views/+contract) · **Merged on green** (post-CI), Leon explicit approval after hands-on testing
- **Origin:** Codex handoff (docs/handoffs/2026-07-13-agent-task-sessions-claude-handoff.md); Tasks 1–6 pre-built, Tasks 7–12 + drafts follow-on built this run.
- **Checks:** swift build clean · ./build-app.sh assembles + worker-contract probe · swift test 1033 pass/1 skip/0 fail (baseline 866) · CI green on the mustard runner
- **Fresh-context reviews:** core Tasks 1–12 (spec SPEC-COMPLETE; quality CRITICAL fixed: structured `outcome:failed` looped uncapped every 2s), drafts+editor (6 Important remediated: draft dedup, honest autosave, symlink confinement, rollback coverage, glyph-hook perf, env landmine doc).
- **What landed:** durable AgentRun/AgentMessage conversations; serial AgentTaskCoordinator behind AgentExecutionGate; Needs You stage releases the slot; every completion → Needs Review; pure AgentTaskQueue/Transition/RetryPolicy (auth pause, 60/300/900s backoff cap 3, gated-action timeouts → completion-uncertain review); bridge reserved for requiresConnectedWorker fallback with results normalized into the conversation; all take-backs route through the coordinator; conversation/reply/review UI + console attention queue; file-backed drafts (`_agent/drafts/<uid>/`, drafts[] contract field, AgentDraft refs, companion side panel with debounced honest autosave + resolvedDraftURL symlink confinement); merged main's PR #96 marker hiding and added a staleness stamp + IndexSet span pre-check to the glyph hook.
- **Safety:** drafts only — worker contract forbids sending/posting; task UID is binding idempotency metadata for ticket creation.
- **Follow-ups (tracked):** running agent-lane→agent-lane drag doesn't cancel the live turn; pre-existing iOS shared-view-atom build break; bridge failed-result re-export has no retry cap; learning loop is phase two (docs/superpowers/plans/2026-07-13-agent-learning-loop.md).
- **Outward actions:** none
- **Revert:** `git revert d04a340`
