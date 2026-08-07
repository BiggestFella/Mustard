# Mustard agent task sessions — Claude handoff

**Status date:** 2026-07-13  
**Audience:** Claude/Codex implementation session taking over the remaining work  
**Current branch:** `codex/agent-task-sessions-implementation`  
**Current HEAD:** `16a5e9253d7b4b45b88f5cb7ee74016b652ad7de`  
**Worktree:** `/Users/leoncreed-baker/Documents/Cavehole/Mustard/.worktrees/agent-task-sessions-implementation`

## Read this first

Continue in the existing isolated worktree and branch above. Do not recreate the work,
switch back to the original checkout, merge, push, or open a PR.

Leon's hard gate remains in force:

> Do not merge to `main` until Leon has thoroughly tested the feature and explicitly
> approves the merge.

The authoritative project guide is the user-owned file at:

`/Users/leoncreed-baker/Documents/Cavehole/Mustard/AGENTS.md`

It is intentionally not tracked in this implementation worktree. Read it before making
changes and do not add, move, edit, or delete it.

Also read these files completely:

- `docs/specs/2026-07-13-agent-task-sessions-design.md`
- `docs/superpowers/plans/2026-07-13-agent-task-sessions-core.md`
- `docs/superpowers/plans/2026-07-13-agent-learning-loop.md`

The plans describe the approved direction, but the implementation has deliberately been
hardened beyond some original snippets. Treat the current reviewed code and the notes in
this handoff as authoritative where an old snippet uses an obsolete API.

## Product decisions already made

- Mustard has one serial local agent execution slot for the MVP.
- A task asking Leon a question moves to **Needs You**, releases the slot, and does not
  block the next queued task.
- Simple work can complete in one turn. Longer work retains one resumable conversation
  and provider session per task.
- Every completed agent task goes to **Needs Review**. There is no silent completion.
- Shortcut and Jira creation are allowed, but the resulting task/output is reviewed.
- Email and message actions create drafts only. The worker must never send them.
- Irreversible outward actions remain prohibited by the bundled worker contract.
- The default worker is the local Claude CLI adapter. The design remains
  provider-neutral so a Codex adapter can be added later.
- The legacy file bridge is only an explicit connected-worker fallback.
- The learning loop is a second phase after the core delegated-task workflow is testable.

## Current dirty working tree — preserve it

At handoff, `git status --short` contains:

```text
 M Tests/MustardTests/AgentTaskCoordinatorTests.swift
```

Do not discard this change. It adds the currently red/unfinished regression:

```swift
test_takeBackSupportsAgentOwnedProposedAndApprovalStages()
```

The test expects `AgentTaskCoordinator.takeBack` to support agent-owned `.inbox` proposed
tasks and `.needsApproval` tasks, returning both to Leon as `.me/.planned`. It was the
start of the remaining Task 7 UI/take-back correction when the previous agent ran out of
credits.

This handoff document itself will also be untracked until it is committed.

## What is complete and reviewed

Core Tasks 1–6 are implemented, tested, spec-reviewed, and quality-reviewed:

1. **Needs You board state and attention counts**
   - Added `.needsInput` without changing existing raw values.
   - Updated board columns, review focus, badges, and neutral “items waiting” copy.

2. **Durable conversations**
   - One `AgentRun` per task and ordered `AgentMessage` history.
   - Stable ordering uses `sequence → createdAt → uid`.
   - Models are registered in the app, previews, and all applicable test schemas.

3. **Structured worker contract and prompts**
   - Provider-compatible JSON schema and semantic post-validation.
   - Worker contract is bundled and copied into the assembled app.
   - Recovery prompts are bounded by count and byte budgets.
   - Task UID is binding idempotency metadata for Shortcut/Jira creation.
   - `build-app.sh` verifies the packaged contract without opening the app.

4. **Pure queue, routing, and transition decisions**
   - Deterministic priority/age/UID selection.
   - Needs You and connected-worker tasks do not occupy the local slot.
   - Cancellation includes ownership `.me` so Planned work remains visible.

5. **Hardened resumable Claude runtime**
   - Prompts travel over stdin rather than argv.
   - Real `structured_output` is decoded.
   - stdout/stderr use one blocking reader per pipe.
   - Cancellation is generation-safe and uses TERM then bounded KILL fallback.
   - Runtime responses cannot represent invalid success/failure combinations.
   - Authentication classification uses trusted channels and health confirmation.
   - The runtime passed focused, full, and Thread Sanitizer review before integration.

6. **Serial task coordinator**
   - Start, resume, Needs You, reply, request changes, accept, take back, session recovery,
     connected fallback, authentication pause, and interrupted-run recovery.
   - Late results cannot overwrite a durable take-back/cancel action.
   - SwiftData failures use narrow snapshots and compensating persistence without
     rolling back unrelated edits.
   - Unroutable work does not starve later routable tasks.
   - Review commands are legal-state guarded and idempotent.

Core Task 7 was implemented, then four of its six quality-hardening slices were completed:

- `75f935d` — automatic delegated-task pickup and initial conversation creation.
- `1bacd5d` — bridge export restricted to `requiresConnectedWorker == true`.
- `c50f5fe` — shared `AgentExecutionGate` serializes all Claude entry points.
- `b04dd93` — one retained app-owned scheduler replaces window-scoped loops.
- `16a5e92` — delegation/re-delegation is durable, legal-state guarded, and current.

Do not redo those changes.

## Verification state at handoff

The last fully verified pre-hardening Task 7 commit (`75f935d`) had:

- 951 tests passed, 1 skipped, 0 failures.
- `swift build` passed.
- `./build-app.sh` passed and verified the packaged worker contract.

After that:

- The bridge export slice passed 20 focused bridge/service tests.
- The shared execution gate slice passed 73 service/coordinator/gate tests in both
  acquisition orders.
- Scheduler and durable re-delegation changes were committed, but the prior agent ran out
  of credits before a fresh final full-suite/build/package verification.

Therefore, do **not** assume current HEAD is globally green. Finish the immediate work
below, then run all verification commands.

## Immediate work: finish Core Task 7

Complete these two remaining quality fixes before starting Task 8.

### 1. Route macOS “Take back / You” actions through the coordinator

Start with the existing uncommitted regression test.

Required behavior:

- Expand the legal take-back stages so agent-owned proposed `.inbox` and
  `.needsApproval` tasks can return to `.me/.planned` safely.
- Inject `AgentTaskCoordinator` into `MustardBoardCard` and `TaskDetailSheet` via the
  environment already supplied by `MustardApp`.
- In `MustardBoardCard`, the owner “You” action must call `taskAgent.takeBack(task)` for
  agent-owned tasks/runs. Retain `PersonalBoard.reassign` only for genuinely local tasks.
- In `TaskDetailSheet`, replace direct owner/stage mutation in `takeOver()` and obvious
  macOS “Take back” controls with `taskAgent.takeBack(task)`.
- Active agent-tab clicks must remain no-ops. `AgentService.delegate` already enforces
  this, but disabling the active control is useful defense in depth.
- Audit the touched macOS views for another direct “Take back” mutation. Do not broaden
  into the complete Task 11 conversation UI yet.
- Mobile currently still has a direct take-back mutation. Leave that for the mobile/UI
  phase unless the coordinator is first injected into the mobile app safely; document it
  in the eventual Task 11 handoff/review.

Add focused tests for coordinator legal stages where possible. Views are verified with
build + Leon's eyes, not screenshot claims.

### 2. Make launch reconciliation retryable and transactional

Current code:

- `AgentTaskCoordinator.reconcileInterruptedRuns` returns `Void` and ignores save success.
- `MustardAppScheduler.runDelegatedTick` sets `didReconcileTaskRuns = true` immediately
  after calling it.

Required behavior:

- Change reconciliation to `@discardableResult -> Bool` or a throwing equivalent.
- Return failure for fetch or save failure.
- Snapshot and narrowly restore coordinator-touched run/task/message state when the
  recovery save fails. Preserve unrelated dirty edits.
- A retry after a failed save must not append duplicate recovery messages.
- The scheduler sets `didReconcileTaskRuns` only after reconciliation succeeds.
- Do not call `runNext` on a tick where reconciliation has not succeeded.
- A later 2-second tick retries reconciliation after a transient failure.

Use the coordinator's existing injectable `persist` closure to test fail-once behavior.
Add tests for fetch/save failure where practical, successful retry, no duplicate recovery
message, and unrelated dirty-edit preservation.

### 3. Verify and review Task 7

Run at minimum:

```bash
swift test --filter 'AgentExecutionGateTests|AgentServiceTests/test_delegate|AgentTaskCoordinatorTests|BridgeExportTests|AgentBridgeServiceTests'
swift test
swift build
./build-app.sh
git diff --check
git status --short
```

Do not open the native app or claim the UI looks correct. Leon will visually test it.

Commit the remaining Task 7 fixes in small conventional commits ending with:

```text
Co-Authored-By: Claude <noreply@anthropic.com>
```

Then run a read-only spec review and a separate read-only quality review of the complete
Task 7 diff from `b0caee6` to the new HEAD. Fix and re-review any Important/Critical
findings before proceeding.

## Remaining core work after Task 7

Follow `docs/superpowers/plans/2026-07-13-agent-task-sessions-core.md`, with these notes.

### Task 8 — recovery and duplicate-safe retry policy

- Add pure retry decisions and `AgentRun.nextAttemptAt`.
- Authentication pauses globally without consuming the task.
- Safe local failures use bounded 60/300/900-second backoff, capped at three retries.
- Timeout/process ambiguity for ticket and draft actions goes to Needs Review as
  **completion uncertain**, not an automatic retry.
- Reconcile interrupted local work to queued; external creation to uncertain review.
- Pin all test times/timezones.
- Preserve the coordinator's existing narrow rollback and compensating-save behavior.

### Task 9 — connected bridge result normalization

The export gate from Task 9 is already complete in commit `1bacd5d`. Do not reimplement it.

Still required:

- Normalize successful/failed bridge results into `AgentMessage` history.
- Update run state and clear/retain `requiresConnectedWorker` per the plan.
- Consider extracting the coordinator's max-sequence append rule into an internal
  `AgentConversation.append` helper if it avoids unsafe duplication.
- Retain live-order cancellation and historical bookkeeping tests.

### Task 10 — render Needs You and runtime state

- Update board cards, Root, Notch, Timeline, Week, and mobile surfaces listed in the plan.
- Use `Theme` tokens everywhere except the intentionally dark notch.
- Build and ask Leon to visually confirm; do not claim appearance from tests.

### Task 11 — conversation, reply, and review UI

- Add durable transcript, focused question display, reply box, request changes, accept,
  take back, and cancel controls to the task detail flow.
- All commands must call `AgentTaskCoordinator`; never mutate agent task owner/stage
  directly.
- Finish the mobile take-back gap noted above.
- Keep all completed work in Needs Review until Leon explicitly accepts it.

### Task 12 — previews, operations, and MVP verification

- Update preview data and operational documentation.
- Document Claude login recovery, serial execution, Needs You behavior, connected fallback,
  and the no-send/drafts-only safety policy.
- Run the complete focused matrix, full test suite, build, packaged app build, contract
  probe, and strict code-sign verification required by the plan.
- Produce a testable app for Leon, but do not merge, push, or open a PR without permission.

## Learning loop — phase two

The core workflow should be tested by Leon before investing heavily in learning behavior.
When Leon is happy with the core, follow
`docs/superpowers/plans/2026-07-13-agent-learning-loop.md` in order:

1. Persist review evidence, learning proposals, and approved memories.
2. Make proposal eligibility and scope deterministic.
3. Select only relevant approved memories.
4. Record reviews and promote explicitly approved memories.
5. Inject approved learning into future task prompts.
6. Add proposal review and memory management UI.
7. Apply approved skill changes with snapshot and undo.
8. Document and verify the complete learning loop.

Important learning constraints:

- Never silently turn one review into a permanent rule.
- Memories and skill changes require explicit review/approval.
- Skill-file changes require snapshot, diff, validation, and undo.
- Project-scoped learning must not leak into unrelated projects.
- Keep this phase separable so the core MVP remains testable if learning work is paused.

## Non-negotiable engineering constraints

- Use TDD for Logic, Agent parsing/state decisions, and Calendar parsing.
- Pin time and timezone in date tests; do not use ambient AEST boundaries.
- Keep views declarative; decisions belong in Logic/Agent pure helpers.
- Preserve user/unrelated changes in the dirty worktree.
- Never use destructive Git cleanup commands.
- Never weaken the bundled worker safety contract.
- Never put task prompts back into argv; the hardened runtime uses closed-after-write stdin.
- Never parse free-form `result` when Claude supplies `structured_output`.
- Never bypass `AgentExecutionGate` for a Claude invocation.
- Never allow both local runtime and bridge export to claim ordinary queued work.
- Never leave a task `.inProgress/.running` after releasing the coordinator slot.
- Never use a broad SwiftData rollback that can erase unrelated user edits.
- Never send email or post messages; drafts only.
- Never report an external artifact without verifying it.

## Useful commands

```bash
cd /Users/leoncreed-baker/Documents/Cavehole/Mustard/.worktrees/agent-task-sessions-implementation
git branch --show-current
git status --short
git log --oneline -20

swift test --filter AgentTaskCoordinatorTests
swift test --filter ClaudeTaskRuntimeTests
swift test --filter AgentExecutionGateTests
swift test --filter 'BridgeExportTests|BridgeIngestTests|AgentBridgeServiceTests'
swift test
swift build
./build-app.sh
```

Expected branch name:

```text
codex/agent-task-sessions-implementation
```

If it differs, stop and inspect rather than changing branches blindly.

## Recommended session structure for cheaper agents

Use one implementation session per bounded task, followed by two cheaper read-only review
sessions:

1. Implementer: exact task text, worktree, current HEAD, allowed files, tests, commit.
2. Spec reviewer: compare actual diff to the approved task; no edits.
3. Quality reviewer: concurrency, persistence, safety, tests; no edits.
4. Same implementer fixes findings; reviewers re-check.

Do not run independent implementers in parallel in this shared worktree. They will see and
overwrite each other's files. Parallel read-only investigation is fine only when no agent
edits the tree.

## Definition of the next handoff milestone

The core MVP is ready for Leon's thorough test only when:

- Core Tasks 1–12 are complete.
- Full tests and build pass at the final HEAD.
- `build/Mustard.app` is assembled, signed, and its worker contract probe passes.
- Needs You questions can be answered in the normal task chat flow.
- A waiting question does not block the next task.
- Completed work always appears in Needs Review.
- Ordinary local tasks never generate bridge work orders.
- Email/message actions remain drafts and cannot send.
- No merge to `main` has occurred.

