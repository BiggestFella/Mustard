# F27 Console / Board Attention Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Agent Console surface all four "needs you" gates consistently — a two-tier left column (compact, actionable gate rows above rich recommendation cards) with Needs Approval now approvable from triage, and the console/hover/notch "waiting" count unified with the board's.

**Architecture:** Both the console's attention list and the board's columns are pure projections of one field, `task.stage`. This adds an `inFlight` bucket + a `gateAction` helper to the pure `AgentInbox` logic, then rebuilds the console's attention section to render that bucket with per-gate inline actions that reuse the board's existing `PersonalBoard.approveTarget` advance. No new models; ADR-0010 (board owns review) intact.

**Tech Stack:** Swift 5.9 / SwiftUI / SwiftData, SPM package (`MustardKit` lib + `Mustard` exe), XCTest. Design tokens from `Sources/MustardKit/Logic/Theme.swift`.

**Spec:** `docs/specs/2026-07-24-console-board-attention-consolidation-design.md`

---

## File Structure

- `Sources/MustardKit/Logic/AgentInbox.swift` — pure logic. Gains `AgentAttention.inFlight`, a `gateAction(for:)` helper, and a widened `attentionTaskCount`. (Task 1, cleanup in Task 3.)
- `Sources/MustardKit/Views/AgentConsoleView.swift` — the view. Its two `NEEDS YOU`/`NEEDS REVIEW` sections + `attentionRow(_:)` are replaced by one `IN FLIGHT` tier + `gateRow(_:)` with inline gate buttons. (Task 2.)
- `Tests/MustardTests/AgentInboxTests.swift` — extend with `inFlight`, count, and `gateAction` cases (Task 1); retarget the two old `attention` tests (Task 3).

No board files change: `MustardBoardCard`/`BoardView`/`PersonalBoard` already render and advance all three gate stages. The console reuses `PersonalBoard.approveTarget` + `PersonalBoard.move` exactly as `MustardBoardCard.approveGate` does.

---

## Task 1: AgentInbox — `inFlight` bucket, `gateAction` helper, unified count (pure, TDD)

**Files:**
- Modify: `Sources/MustardKit/Logic/AgentInbox.swift`
- Test: `Tests/MustardTests/AgentInboxTests.swift`

This task keeps the existing `questions`/`reviews` fields so `AgentConsoleView` still compiles; Task 3 removes them after the view migrates.

- [ ] **Step 1: Write the failing tests**

Add these three methods inside `final class AgentInboxTests` in `Tests/MustardTests/AgentInboxTests.swift` (after the existing `test_attention_emptyWhenNothingWaiting`, before the closing brace):

```swift
    // MARK: F27 — in-flight bucket + gate actions + unified count

    func test_attention_inFlight_allThreeGatesOldestFirst_excludingOthers() {
        let ap = MustardTask(title: "ap"); ap.stage = .needsApproval; ap.createdAt = Date(timeIntervalSince1970: 150)
        let q1 = MustardTask(title: "q1"); q1.stage = .needsInput; q1.createdAt = Date(timeIntervalSince1970: 200)
        let q2 = MustardTask(title: "q2"); q2.stage = .needsInput; q2.createdAt = Date(timeIntervalSince1970: 100)
        let r1 = MustardTask(title: "r1"); r1.stage = .needsReview; r1.createdAt = Date(timeIntervalSince1970: 300)
        let wip = MustardTask(title: "wip"); wip.stage = .inProgress
        let queued = MustardTask(title: "queued"); queued.stage = .queued

        let attention = AgentInbox.attention([q1, r1, wip, q2, ap, queued])

        // Oldest-first across all three gate stages: q2(100) ap(150) q1(200) r1(300)
        XCTAssertEqual(attention.inFlight.map(\.title), ["q2", "ap", "q1", "r1"])
    }

    func test_attentionTaskCount_includesNeedsApproval() {
        let ap = MustardTask(title: "ap"); ap.stage = .needsApproval
        let q = MustardTask(title: "q"); q.stage = .needsInput
        let rev = MustardTask(title: "rev"); rev.stage = .needsReview
        let planned = MustardTask(title: "p"); planned.stage = .planned

        XCTAssertEqual(AgentInbox.attentionTaskCount([ap, q, rev, planned]), 3)
    }

    func test_gateAction_perStage() {
        XCTAssertEqual(AgentInbox.gateAction(for: .needsApproval)?.label, "Approve")
        XCTAssertEqual(AgentInbox.gateAction(for: .needsApproval)?.oneClick, true)
        XCTAssertEqual(AgentInbox.gateAction(for: .needsInput)?.label, "Answer")
        XCTAssertEqual(AgentInbox.gateAction(for: .needsInput)?.oneClick, false)
        XCTAssertEqual(AgentInbox.gateAction(for: .needsReview)?.label, "Accept")
        XCTAssertEqual(AgentInbox.gateAction(for: .needsReview)?.oneClick, true)
        XCTAssertNil(AgentInbox.gateAction(for: .planned))
        XCTAssertNil(AgentInbox.gateAction(for: .queued))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AgentInboxTests`
Expected: FAIL — compile errors (`value of type 'AgentAttention' has no member 'inFlight'`; `type 'AgentInbox' has no member 'gateAction'`).

- [ ] **Step 3: Add `inFlight` to `AgentAttention` and populate it**

In `Sources/MustardKit/Logic/AgentInbox.swift`, change the struct (currently ~lines 26-29) to add the field:

```swift
    public struct AgentAttention {
        public let questions: [MustardTask]
        public let reviews: [MustardTask]
        /// All three gate stages (needsApproval ∪ needsInput ∪ needsReview) in one
        /// oldest-first list — the console's "In flight · needs you" tier (F27).
        public let inFlight: [MustardTask]
    }
```

Then update `attention(_:)` (currently ~lines 31-41) to build `inFlight` from the same `precedes` comparator:

```swift
    public static func attention(_ tasks: [MustardTask]) -> AgentAttention {
        // Oldest-first, with a uid tiebreak so equal timestamps order deterministically
        // (Swift's sort isn't stable) — matches AgentRun.orderedMessages / AgentTaskQueue.
        func precedes(_ a: MustardTask, _ b: MustardTask) -> Bool {
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.uid < b.uid
        }
        let gateStages: Set<TaskStage> = [.needsApproval, .needsInput, .needsReview]
        return AgentAttention(
            questions: tasks.filter { $0.stage == .needsInput }.sorted(by: precedes),
            reviews: tasks.filter { $0.stage == .needsReview }.sorted(by: precedes),
            inFlight: tasks.filter { gateStages.contains($0.stage) }.sorted(by: precedes)
        )
    }
```

- [ ] **Step 4: Add the `gateAction` helper**

In the same file, add this static method to the `AgentInbox` enum (e.g. directly after `attention(_:)`):

```swift
    /// The console gate row's primary button for a stage: its label, and whether it
    /// advances in one click (Approve/Accept, via PersonalBoard.approveTarget) or must
    /// open the conversation (Answer — replying needs typing). Nil for non-gate stages.
    public static func gateAction(for stage: TaskStage) -> (label: String, oneClick: Bool)? {
        switch stage {
        case .needsApproval: return ("Approve", true)
        case .needsInput: return ("Answer", false)
        case .needsReview: return ("Accept", true)
        default: return nil
        }
    }
```

- [ ] **Step 5: Widen `attentionTaskCount` to include Needs Approval**

Change `attentionTaskCount` (currently ~lines 20-22) so the console/hover/notch count matches the board's `PersonalBoard.waitingCount`:

```swift
    /// Agent tasks awaiting your approval, answer, or output review (all three gate
    /// stages) — matches PersonalBoard.waitingCount/needsHuman (F27 count unification).
    public static func attentionTaskCount(_ tasks: [MustardTask]) -> Int {
        tasks.filter {
            $0.stage == .needsApproval || $0.stage == .needsInput || $0.stage == .needsReview
        }.count
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter AgentInboxTests`
Expected: PASS (all cases, including the pre-existing `test_waitingCount_*`, `test_attention_*`, `test_dockText_*`).

- [ ] **Step 7: Confirm the whole suite still builds and passes**

Run: `swift build && swift test`
Expected: build succeeds; full suite PASS. (Existing count surfaces — `RootView`, `TodayView`, `NotchSurface`, `MorningRitualView` — now include Needs Approval in their totals; this is intended and touches no test expectations.)

- [ ] **Step 8: Commit**

```bash
git add Sources/MustardKit/Logic/AgentInbox.swift Tests/MustardTests/AgentInboxTests.swift
git commit -m "feat(agent): AgentInbox inFlight bucket + gateAction + unified count (F27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: AgentConsoleView — the two-tier column + `gateRow` (view; build + eye)

Views aren't unit-tested (CLAUDE.md) — verify by `swift build` and Leon's eye-check.

**Files:**
- Modify: `Sources/MustardKit/Views/AgentConsoleView.swift`

- [ ] **Step 1: Replace the two attention sections with one In-flight tier**

In `masterColumn`, replace this block (currently ~lines 73-80):

```swift
                if !attention.questions.isEmpty {
                    sectionLabel("NEEDS YOU", count: attention.questions.count)
                    ForEach(attention.questions) { attentionRow($0) }
                }
                if !attention.reviews.isEmpty {
                    sectionLabel("NEEDS REVIEW", count: attention.reviews.count)
                    ForEach(attention.reviews) { attentionRow($0) }
                }
```

with:

```swift
                if !attention.inFlight.isEmpty {
                    sectionLabel("IN FLIGHT · NEEDS YOU", count: attention.inFlight.count)
                    ForEach(attention.inFlight) { gateRow($0) }
                }
```

- [ ] **Step 2: Replace `attentionRow(_:)` with `gateRow(_:)` + helpers**

Delete the existing `attentionRow(_:)` method (currently ~lines 305-328, from its doc-comment through its closing brace) and add these methods in its place:

```swift
    /// The gate-kind spine colour: purple (approval), amber (answer), green (review).
    private func gateSpineColor(_ stage: TaskStage) -> Color {
        switch stage {
        case .needsApproval: return Theme.Palette.agent
        case .needsInput: return Theme.Palette.warning
        case .needsReview: return Theme.Palette.done
        default: return Theme.Palette.hairline
        }
    }

    /// The muted sub-meta line under a gate row's title.
    private func gateSubmeta(_ task: MustardTask) -> String {
        switch task.stage {
        case .needsApproval: return task.isGated ? "gated · approve to run" : "approve to run"
        case .needsInput: return "agent asked · your answer needed"
        case .needsReview: return "finished · check the output"
        default: return ""
        }
    }

    /// One-click advance for a gate row, mirroring MustardBoardCard.approveGate: the
    /// pure PersonalBoard.approveTarget decides the destination (needsApproval → queued
    /// / needsReview; needsReview → done), so acting here and on the board stay coherent.
    private func advanceGate(_ task: MustardTask) {
        guard let target = PersonalBoard.approveTarget(for: task) else { return }
        PersonalBoard.move(task, to: target)
    }

    /// A compact, actionable gate row (Needs Approval / You / Review) — deliberately
    /// distinct from the rich proposal cards. Tapping the row opens the conversation
    /// sheet; the trailing button either advances in one click or opens the sheet.
    private func gateRow(_ task: MustardTask) -> some View {
        let action = AgentInbox.gateAction(for: task.stage)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(gateSpineColor(task.stage))
                .frame(width: 3)
            if let area = task.list?.area {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: area.colorHex)).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(gateSubmeta(task)).font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action {
                Button {
                    if action.oneClick { advanceGate(task) } else { selectedTask = task }
                } label: {
                    Text(action.label)
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .foregroundStyle(action.oneClick ? .white : Theme.Palette.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background {
                            if action.oneClick {
                                RoundedRectangle(cornerRadius: 7).fill(gateSpineColor(task.stage))
                            } else {
                                RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.hairline, lineWidth: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { selectedTask = task }
        .padding(.bottom, 8)
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds with no errors or warnings about `attentionRow` (it's gone) or unused symbols.

- [ ] **Step 4: Eye-check (Leon)**

Run: `./build-app.sh && open build/Mustard.app`
Ask Leon to confirm in the Agent console: (a) an "In flight · needs you" tier shows Needs Approval / Needs You / Needs Review rows with the purple/amber/green spines; (b) `Approve` and `Accept` advance the task in one click and it disappears from the tier; (c) `Answer` and tapping a row open the conversation sheet; (d) the Recommendations tier still shows rich proposal cards. Do not claim it "looks right" — state it builds/runs and wait for Leon.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Views/AgentConsoleView.swift
git commit -m "feat(agent): console two-tier attention — gate rows vs proposals (F27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Remove the now-dead `questions`/`reviews` fields (pure, TDD)

Nothing renders `questions`/`reviews` after Task 2. This is a pure refactor — the suite stays green throughout; the guard is "nothing still references the removed fields."

**Files:**
- Modify: `Sources/MustardKit/Logic/AgentInbox.swift`
- Test: `Tests/MustardTests/AgentInboxTests.swift`

- [ ] **Step 1: Remove the fields from the struct and `attention(_:)`**

In `Sources/MustardKit/Logic/AgentInbox.swift`, reduce `AgentAttention` to one field:

```swift
    /// The single attention bucket for the console's "In flight · needs you" tier:
    /// all three gate stages (needsApproval ∪ needsInput ∪ needsReview), oldest-first.
    public struct AgentAttention {
        public let inFlight: [MustardTask]
    }
```

and simplify `attention(_:)` to build only `inFlight`:

```swift
    public static func attention(_ tasks: [MustardTask]) -> AgentAttention {
        // Oldest-first, with a uid tiebreak so equal timestamps order deterministically
        // (Swift's sort isn't stable) — matches AgentRun.orderedMessages / AgentTaskQueue.
        func precedes(_ a: MustardTask, _ b: MustardTask) -> Bool {
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.uid < b.uid
        }
        let gateStages: Set<TaskStage> = [.needsApproval, .needsInput, .needsReview]
        return AgentAttention(
            inFlight: tasks.filter { gateStages.contains($0.stage) }.sorted(by: precedes)
        )
    }
```

- [ ] **Step 2: Retarget the two old attention tests to `inFlight`**

The suite won't compile now — the two old tests still reference `.questions`/`.reviews`. In `Tests/MustardTests/AgentInboxTests.swift`, replace `test_attention_groupsQuestionsAndReviewsOldestFirst_excludingOtherStages` and `test_attention_emptyWhenNothingWaiting` (currently ~lines 58-76) with a single test:

```swift
    func test_attention_emptyWhenNothingWaiting() {
        let planned = MustardTask(title: "p"); planned.stage = .planned
        let attention = AgentInbox.attention([planned])
        XCTAssertTrue(attention.inFlight.isEmpty)
    }
```

(The oldest-first / stage-inclusion behaviour is already covered by `test_attention_inFlight_allThreeGatesOldestFirst_excludingOthers` from Task 1, so the old grouping test is dropped rather than duplicated.)

- [ ] **Step 3: Run the full suite**

Run: `swift build && swift test`
Expected: build succeeds; full suite PASS. (If a compile error names `.questions`/`.reviews` anywhere else, that reference was missed in Task 2 — fix it before continuing.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Logic/AgentInbox.swift Tests/MustardTests/AgentInboxTests.swift
git commit -m "refactor(agent): collapse AgentAttention to single inFlight bucket (F27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria

- `swift build` and `swift test` both pass.
- Agent console shows one "In flight · needs you" tier (all three gate stages, gate-colored spines, inline `Approve`/`Answer`/`Accept`) above the unchanged Recommendations tier.
- Approving/accepting from the console advances the same `task.stage` the board reads, so the item leaves both surfaces; the "waiting on you" count in the hover dock / notch / sidebar now includes Needs Approval, matching the board.
- No new model, no execution-semantics change, no board file changes.
