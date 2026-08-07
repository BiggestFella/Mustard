# Resumable Agent Task Sessions — Core MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Mustard automatically pick up delegated tasks, pause for human answers without blocking the queue, resume the same Claude session, and send every result to a unified Needs Review flow.

**Architecture:** Keep `AgentService` responsible for source sweeps and recommendation triage. Add a focused `AgentTaskCoordinator` that owns one active delegated-task turn, persists `AgentRun`/`AgentMessage` records in SwiftData, and calls a provider-neutral `AgentRuntime`; ship `ClaudeTaskRuntime` first and preserve the file bridge only for explicit connected-worker fallback. All queue selection, routing, transition, retry, and recovery decisions stay in pure `Logic/` units.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, Observation, Foundation `Process`, XCTest, Claude CLI subscription auth.

---

## Scope and dependency boundary

This plan delivers slices 1–4 of the approved design spec:

- durable task conversation and `Needs You` stage
- Claude start/resume runtime and serial coordinator
- question/reply/revision/review UI
- recovery, retry, idempotency guidance, and connected-worker fallback normalization

Approved reusable learning is intentionally a second plan:
`docs/superpowers/plans/2026-07-13-agent-learning-loop.md`. Codex runtime,
parallel execution, live token streaming, and automatic connected-session launch remain
fast-follows.

## File structure

### New files

| File | Responsibility |
|---|---|
| `Sources/MustardKit/Models/AgentRun.swift` | Durable provider session and run state for one task conversation |
| `Sources/MustardKit/Models/AgentMessage.swift` | Ordered human/agent/system timeline entries |
| `Sources/MustardKit/Logic/AgentTaskQueue.swift` | Pure runnable-task selection and project routing |
| `Sources/MustardKit/Logic/AgentTaskTransition.swift` | Pure outcome → task/run transition decisions |
| `Sources/MustardKit/Logic/AgentRetryPolicy.swift` | Pure retry, authentication pause, and uncertain-completion rules |
| `Sources/MustardKit/Agent/AgentTurnContract.swift` | Structured request/result types and JSON decoding |
| `Sources/MustardKit/Agent/AgentTaskPrompt.swift` | Compose first-turn, resume, and lost-session recovery prompts |
| `Sources/MustardKit/Agent/AgentRuntime.swift` | Provider-neutral start/resume/cancel/health interface |
| `Sources/MustardKit/Agent/ClaudeTaskRuntime.swift` | Claude CLI session arguments, invocation, and result parsing |
| `Sources/MustardKit/Agent/AgentTaskCoordinator.swift` | SwiftData orchestration for delegate/run/reply/review/recovery |
| `Sources/MustardKit/Agent/Prompts/MustardAgentContract.md` | Provider-neutral worker safety and output contract |
| `Sources/MustardKit/Views/AgentConversationView.swift` | Timeline, question composer, results, artifacts, and review feedback |
| `Tests/MustardTests/AgentRunModelTests.swift` | SwiftData model persistence and ordering |
| `Tests/MustardTests/AgentTaskQueueTests.swift` | Scheduling and route selection |
| `Tests/MustardTests/AgentTaskTransitionTests.swift` | Full transition matrix |
| `Tests/MustardTests/AgentTurnContractTests.swift` | Structured result decoding and malformed-output rejection |
| `Tests/MustardTests/AgentTaskPromptTests.swift` | Prompt layers, idempotency key, and bounded transcript recovery |
| `Tests/MustardTests/ClaudeTaskRuntimeTests.swift` | New/resume CLI arguments and provider error mapping |
| `Tests/MustardTests/AgentTaskCoordinatorTests.swift` | End-to-end coordinator behavior with a stub runtime |
| `Tests/MustardTests/AgentRetryPolicyTests.swift` | Retry and duplicate-risk policy |

### Existing files changed

| File | Change |
|---|---|
| `Package.swift` | Bundle the markdown worker contract as a MustardKit resource |
| `Sources/MustardKit/Models/TaskStage.swift` | Add `needsInput` and update board column sets |
| `Sources/MustardKit/Models/MustardTask.swift` | Add optional inverse link to `AgentRun` |
| `Sources/MustardKit/MustardContainer.swift` | Register new SwiftData models |
| `Sources/MustardKit/PreviewData.swift` | Register models and add conversation samples |
| `Sources/MustardKit/Logic/PersonalBoard.swift` | Include Needs You in attention/review stages and agent lanes |
| `Sources/MustardKit/Logic/AgentInbox.swift` | Count questions plus outputs waiting on Leon |
| `Sources/MustardKit/Agent/ClaudeRunner.swift` | Extract reusable process invocation while preserving the existing `ClaudeRun` API |
| `Sources/MustardKit/Agent/AgentService.swift` | Create the durable run/message when delegation succeeds; stop treating ordinary delegated work as bridge-first |
| `Sources/MustardKit/Logic/BridgeExport.swift` | Export only runs explicitly marked for connected fallback |
| `Sources/MustardKit/Logic/BridgeIngest.swift` | Normalize connected results into the task conversation |
| `Sources/Mustard/MustardApp.swift` | Own/inject/tick `AgentTaskCoordinator`; reconcile interrupted runs at launch |
| `Sources/MustardKit/Views/TaskDetailSheet.swift` | Mount the conversation and route reply/review actions to the coordinator |
| `Sources/MustardKit/Views/BoardView.swift` | Show Needs You in the board and review-focus lanes |
| `Sources/MustardKit/Views/MustardBoardCard.swift` | Render working/question/review states and inline actions |
| `Sources/MustardKit/Views/AgentConsoleView.swift` | Add a unified task review/question queue |
| `Sources/MustardKit/Views/RootView.swift` and `Sources/MustardKit/Views/NotchSurface.swift` | Include Needs You in waiting counts |
| `Sources/MustardKit/Views/TimelineRow.swift` and `Sources/MustardKit/Views/WeekView.swift` | Keep delegation actions creating durable runs |
| `CLAUDE.md`, `docs/architecture.md`, `docs/build-order.md`, `docs/agent-bridge-contract.md` | Replace stale manual-worker/default-flow documentation |

## Task 1: Add the Needs You board stage and attention counts

**Files:**
- Modify: `Sources/MustardKit/Models/TaskStage.swift`
- Modify: `Sources/MustardKit/Logic/PersonalBoard.swift`
- Modify: `Sources/MustardKit/Logic/AgentInbox.swift`
- Test: `Tests/MustardTests/TaskStageTests.swift`
- Test: `Tests/MustardTests/StageBoardTests.swift`
- Test: `Tests/MustardTests/BoardFocusTests.swift`
- Test: `Tests/MustardTests/AgentInboxTests.swift`

- [ ] **Step 1: Write failing stage and attention tests**

Add these assertions to the existing suites:

```swift
func test_needsInput_isAnAgentGateShownBeforeNeedsReview() {
    XCTAssertEqual(TaskStage.needsInput.label, "Needs You")
    XCTAssertEqual(TaskStage.needsInput.kind, .gate)
    XCTAssertEqual(BoardOwnerView.agent.columns,
        [.inbox, .forAgent, .needsApproval, .queued, .inProgress,
         .needsInput, .needsReview, .done])
}

func test_waitingCount_includesNeedsInput() {
    let question = task(.needsInput, owner: .agent)
    let review = task(.needsReview, owner: .agent)
    XCTAssertEqual(PersonalBoard.waitingCount(
        [question, review], view: .everyone, area: .all), 2)
    XCTAssertEqual(PersonalBoard.agentBadge([question, review]), 2)
}

func test_gateStages_includeQuestionApprovalAndReview_inPipelineOrder() {
    XCTAssertEqual(PersonalBoard.gateStages,
                   [.needsApproval, .needsInput, .needsReview])
}

func test_waitingCount_countsQuestionAndOutputTasks() {
    let question = MustardTask(title: "answer me"); question.stage = .needsInput
    let review = MustardTask(title: "review me"); review.stage = .needsReview
    XCTAssertEqual(AgentInbox.waitingCount(
        recommendations: [], tasks: [question, review], now: now), 2)
}
```

- [ ] **Step 2: Run the focused tests and confirm the enum case is missing**

Run:

```bash
swift test --filter 'TaskStageTests|StageBoardTests|BoardFocusTests|AgentInboxTests'
```

Expected: compilation fails because `TaskStage.needsInput` does not exist.

- [ ] **Step 3: Add `needsInput` and update every exhaustive stage mapping**

In `TaskStage.swift`, use this pipeline:

```swift
case inbox, planned, scheduled, forAgent, needsApproval,
     queued, inProgress, needsInput, needsReview, blocked, done
```

Map it as follows:

```swift
case .needsInput: "Needs You"
```

```swift
case .needsInput: "answer the agent"
```

```swift
case .needsApproval, .needsInput, .needsReview: .gate
```

Set the board columns exactly to:

```swift
case .everyone:
    [.inbox, .planned, .scheduled, .forAgent, .needsApproval,
     .queued, .inProgress, .needsInput, .needsReview, .blocked, .done]
case .mine:
    [.inbox, .planned, .scheduled, .inProgress, .blocked, .done]
case .agent:
    [.inbox, .forAgent, .needsApproval, .queued, .inProgress,
     .needsInput, .needsReview, .done]
```

In `PersonalBoard`, change the shared sets and predicates to:

```swift
public static let gateStages: [TaskStage] =
    [.needsApproval, .needsInput, .needsReview]

public static let agentLaneStages: Set<TaskStage> =
    [.forAgent, .needsApproval, .queued, .inProgress, .needsInput, .needsReview]

private static func needsHuman(_ task: MustardTask) -> Bool {
    task.stage == .needsApproval || task.stage == .needsInput || task.stage == .needsReview
}
```

Use `needsHuman` from both `waitingCount` and `agentBadge`. In `AgentInbox`, count both
`needsInput` and `needsReview` task rows in `outputCount` and update the comment to call
them agent tasks awaiting human attention.

- [ ] **Step 4: Run the focused tests**

Run the command from Step 2.

Expected: all selected tests pass.

- [ ] **Step 5: Commit the board-state foundation**

```bash
git add Sources/MustardKit/Models/TaskStage.swift Sources/MustardKit/Logic/PersonalBoard.swift Sources/MustardKit/Logic/AgentInbox.swift Tests/MustardTests/TaskStageTests.swift Tests/MustardTests/StageBoardTests.swift Tests/MustardTests/BoardFocusTests.swift Tests/MustardTests/AgentInboxTests.swift
git commit -m "feat(agent): add needs-you task stage" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 2: Persist one task conversation and ordered messages

**Files:**
- Create: `Sources/MustardKit/Models/AgentRun.swift`
- Create: `Sources/MustardKit/Models/AgentMessage.swift`
- Modify: `Sources/MustardKit/Models/MustardTask.swift`
- Modify: `Sources/MustardKit/MustardContainer.swift`
- Modify: `Sources/MustardKit/PreviewData.swift`
- Create: `Tests/MustardTests/AgentRunModelTests.swift`
- Modify: every test-local `ModelContainer` schema that includes `MustardTask`

- [ ] **Step 1: Write the failing SwiftData round-trip tests**

Create `AgentRunModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import MustardKit

final class AgentRunModelTests: XCTestCase {
    @MainActor
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func test_taskRunAndMessagesRoundTrip() throws {
        let context = try context()
        let task = MustardTask(title: "Prep release")
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL")
        let first = AgentMessage(run: run, sequence: 0, role: .human,
                                 kind: .delegation, content: "Prep release")
        let second = AgentMessage(run: run, sequence: 1, role: .agent,
                                  kind: .question, content: "Which version?")
        context.insert(task); context.insert(run); context.insert(first); context.insert(second)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(fetched.agentRun?.state, .queued)
        XCTAssertEqual(fetched.agentRun?.orderedMessages.map(\.content),
                       ["Prep release", "Which version?"])
    }

    func test_typedAccessorsUseSafeDefaults() {
        let run = AgentRun()
        run.providerRaw = "unknown"; run.stateRaw = "unknown"
        XCTAssertEqual(run.provider, .claude)
        XCTAssertEqual(run.state, .queued)
    }
}
```

- [ ] **Step 2: Run the new test and verify the model types are missing**

```bash
swift test --filter AgentRunModelTests
```

Expected: compilation fails for missing `AgentRun`, `AgentMessage`, and `agentRun`.

- [ ] **Step 3: Add the two focused model files**

Create `AgentRun.swift` with these public types and fields:

```swift
import Foundation
import SwiftData

public enum AgentProvider: String, Codable, CaseIterable { case claude, codex }
public enum AgentRunState: String, Codable, CaseIterable {
    case queued, running, needsInput, completed, failed, cancelled, interrupted
}

@Model
public final class AgentRun {
    public var uid: String = UUID().uuidString
    public var providerRaw: String = AgentProvider.claude.rawValue
    public var stateRaw: String = AgentRunState.queued.rawValue
    public var providerSessionID: String?
    public var workingDirectory: String = ""
    public var project: String = ""
    public var attemptCount: Int = 0
    public var resumeCount: Int = 0
    public var createdAt: Date = .now
    public var startedAt: Date?
    public var lastActivityAt: Date = .now
    public var completedAt: Date?
    public var lastOutcomeRaw: String?
    public var lastError: String?
    public var requiresConnectedWorker: Bool = false
    public var task: MustardTask?
    @Relationship(deleteRule: .cascade, inverse: \AgentMessage.run)
    public var messages: [AgentMessage]? = []

    public var provider: AgentProvider {
        get { AgentProvider(rawValue: providerRaw) ?? .claude }
        set { providerRaw = newValue.rawValue }
    }
    public var state: AgentRunState {
        get { AgentRunState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }
    public var orderedMessages: [AgentMessage] {
        (messages ?? []).sorted { $0.sequence < $1.sequence }
    }

    public init(task: MustardTask? = nil, workingDirectory: String = "", project: String = "") {
        self.task = task; self.workingDirectory = workingDirectory; self.project = project
    }
}
```

Create `AgentMessage.swift`:

```swift
import Foundation
import SwiftData

public enum AgentMessageRole: String, Codable { case human, agent, system }
public enum AgentMessageKind: String, Codable {
    case delegation, question, answer, progress, result, reviewFeedback, recovery, error
}

@Model
public final class AgentMessage {
    public var uid: String = UUID().uuidString
    public var sequence: Int = 0
    public var roleRaw: String = AgentMessageRole.system.rawValue
    public var kindRaw: String = AgentMessageKind.progress.rawValue
    public var content: String = ""
    public var createdAt: Date = .now
    public var links: [TaskLink] = []
    public var providerTurnID: String?
    public var run: AgentRun?

    public var role: AgentMessageRole {
        get { AgentMessageRole(rawValue: roleRaw) ?? .system }
        set { roleRaw = newValue.rawValue }
    }
    public var kind: AgentMessageKind {
        get { AgentMessageKind(rawValue: kindRaw) ?? .progress }
        set { kindRaw = newValue.rawValue }
    }

    public init(run: AgentRun? = nil, sequence: Int = 0, role: AgentMessageRole = .system,
                kind: AgentMessageKind = .progress, content: String = "",
                links: [TaskLink] = []) {
        self.run = run; self.sequence = sequence; self.roleRaw = role.rawValue
        self.kindRaw = kind.rawValue; self.content = content; self.links = links
    }
}
```

Add the inverse to `MustardTask`:

```swift
@Relationship(deleteRule: .cascade, inverse: \AgentRun.task)
public var agentRun: AgentRun?
```

- [ ] **Step 4: Register the models everywhere a MustardTask schema is constructed**

Add `AgentRun.self, AgentMessage.self` to `MustardContainer.make`, `PreviewData`, and each
test-local `ModelContainer` that includes `MustardTask`. Do not change calendar-only or
note-only test schemas.

- [ ] **Step 5: Run model and existing agent tests**

```bash
swift test --filter 'AgentRunModelTests|AgentTests|AgentBridgeServiceTests|ModelTests'
```

Expected: all selected tests pass with no SwiftData inverse/schema errors.

- [ ] **Step 6: Commit the durable conversation models**

```bash
git add Sources/MustardKit/Models/AgentRun.swift Sources/MustardKit/Models/AgentMessage.swift Sources/MustardKit/Models/MustardTask.swift Sources/MustardKit/MustardContainer.swift Sources/MustardKit/PreviewData.swift Tests/MustardTests
git commit -m "feat(agent): persist task conversations" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 3: Define the structured turn and worker instruction contract

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MustardKit/Agent/AgentTurnContract.swift`
- Create: `Sources/MustardKit/Agent/AgentTaskPrompt.swift`
- Create: `Sources/MustardKit/Agent/Prompts/MustardAgentContract.md`
- Create: `Tests/MustardTests/AgentTurnContractTests.swift`
- Create: `Tests/MustardTests/AgentTaskPromptTests.swift`

- [ ] **Step 1: Write failing contract decoding tests**

```swift
import XCTest
@testable import MustardKit

final class AgentTurnContractTests: XCTestCase {
    func test_decodesNeedsInput() throws {
        let json = #"{"outcome":"needs_input","message":"I need the version","questions":["Which version?"],"summary":"","artifacts":[],"retryDisposition":"none"}"#
        let result = try AgentTurnContract.decode(json)
        XCTAssertEqual(result.outcome, .needsInput)
        XCTAssertEqual(result.questions, ["Which version?"])
    }

    func test_decodesCompletedArtifact() throws {
        let json = #"{"outcome":"completed","message":"Created it","questions":[],"summary":"Created Shortcut 123","artifacts":[{"label":"Shortcut","url":"https://app.shortcut.com/x/123"}],"retryDisposition":"none"}"#
        let result = try AgentTurnContract.decode(json)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.artifacts.first?.label, "Shortcut")
    }

    func test_rejectsUnknownOutcomeAndProse() {
        XCTAssertThrowsError(try AgentTurnContract.decode(#"{"outcome":"done"}"#))
        XCTAssertThrowsError(try AgentTurnContract.decode("looks good"))
    }

    func test_workerContractContainsHardSafetyRules() throws {
        let text = try AgentTurnContract.workerContract()
        XCTAssertTrue(text.contains("Never send email"))
        XCTAssertTrue(text.contains("Needs Review"))
        XCTAssertTrue(text.contains("missing skill is not a reason to decline"))
    }
}
```

- [ ] **Step 2: Run the test and verify the contract types are missing**

```bash
swift test --filter AgentTurnContractTests
```

Expected: compilation fails for missing `AgentTurnContract`.

- [ ] **Step 3: Add the provider-neutral Codable types**

Create `AgentTurnContract.swift`:

```swift
import Foundation

public enum AgentTurnOutcome: String, Codable, Equatable {
    case completed
    case needsInput = "needs_input"
    case failed
    case cancelled
    case requiresConnectedWorker = "requires_connected_worker"
}

public enum AgentRetryDisposition: String, Codable, Equatable {
    case none, safe, backoff, uncertain
}

public struct AgentArtifact: Codable, Equatable, Sendable {
    public let label: String
    public let url: String
    public init(label: String, url: String) { self.label = label; self.url = url }
}

public struct AgentTurnResult: Codable, Equatable, Sendable {
    public let outcome: AgentTurnOutcome
    public let message: String
    public let questions: [String]
    public let summary: String
    public let artifacts: [AgentArtifact]
    public let retryDisposition: AgentRetryDisposition
    public let errorCategory: String?
    public let connectedCapability: String?
}

public enum AgentTurnContract {
    public static let jsonSchema = #"{
      "type":"object",
      "additionalProperties":false,
      "properties":{
        "outcome":{"type":"string","enum":["completed","needs_input","failed","cancelled","requires_connected_worker"]},
        "message":{"type":"string"},
        "questions":{"type":"array","items":{"type":"string"}},
        "summary":{"type":"string"},
        "artifacts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"label":{"type":"string"},"url":{"type":"string"}},"required":["label","url"]}},
        "retryDisposition":{"type":"string","enum":["none","safe","backoff","uncertain"]},
        "errorCategory":{"type":["string","null"]},
        "connectedCapability":{"type":["string","null"]}
      },
      "required":["outcome","message","questions","summary","artifacts","retryDisposition"]
    }"#

    public static func decode(_ text: String) throws -> AgentTurnResult {
        try JSONDecoder().decode(AgentTurnResult.self, from: Data(text.utf8))
    }

    public static func workerContract() throws -> String {
        guard let url = Bundle.module.url(forResource: "MustardAgentContract", withExtension: "md",
                                          subdirectory: "Prompts") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
```

The JSON schema passed to Claude must require all non-optional keys above and restrict
`outcome`/`retryDisposition` to the enum raw values.

- [ ] **Step 4: Bundle the prompt resource and write its exact behavioural contract**

Change the MustardKit target in `Package.swift` to:

```swift
.target(
    name: "MustardKit",
    path: "Sources/MustardKit",
    resources: [.process("Agent/Prompts")]
),
```

Create `MustardAgentContract.md` with these binding sections:

```markdown
# Mustard delegated-task worker contract

Work only on the assigned task. Endeavour to complete it with the supplied task,
project instructions, knowledge base, approved memories, and relevant skills. A
missing skill is not a reason to decline.

Ask focused questions when required context cannot be discovered. Never fabricate
scope, completion, verification, or artifact links.

Allowed: research, analysis, local files, code, vault notes, verified Shortcut/Jira
creation, email drafts, and message drafts. Never send email, post messages, purchase,
publish, delete external data, or take another irreversible outward action.

Verify every artifact before reporting completion. Every completed task returns to
Mustard Needs Review. Return only the JSON object required by the supplied schema.
Use `requires_connected_worker` when a required capability is unavailable in this CLI.
```

- [ ] **Step 5: Run the contract tests**

Before running, create `AgentTaskPromptTests.swift` with these tests:

```swift
func test_firstTurn_containsContractTaskAndStableIdempotencyKey() {
    let task = MustardTask(title: "Create release ticket")
    task.uid = "task-123"; task.notes = "Release 2.21.0"; task.actionType = .ticket
    let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL")
    let prompt = AgentTaskPrompt.firstTurn(
        task: task, run: run, contract: "Never send email", approvedInstructions: [])
    XCTAssertTrue(prompt.contains("Never send email"))
    XCTAssertTrue(prompt.contains("Create release ticket"))
    XCTAssertTrue(prompt.contains("Release 2.21.0"))
    XCTAssertTrue(prompt.contains("Mustard task UID: task-123"))
}

func test_resume_containsLatestAnswerAndCompactContractReminder() {
    let task = MustardTask(title: "Prep release")
    let run = AgentRun(task: task)
    let prompt = AgentTaskPrompt.resume(
        run: run, latestHumanMessage: "Use 2.21.0",
        contractReminder: "Return structured JSON", approvedInstructions: [])
    XCTAssertTrue(prompt.contains("Use 2.21.0"))
    XCTAssertTrue(prompt.contains("Return structured JSON"))
}

func test_recovery_ordersTranscriptAndCapsItAtFortyMessages() {
    let task = MustardTask(title: "Long task")
    let run = AgentRun(task: task)
    run.messages = (0..<45).map {
        AgentMessage(run: run, sequence: $0, role: $0.isMultiple(of: 2) ? .human : .agent,
                     kind: .progress, content: "message-\($0)")
    }
    let prompt = AgentTaskPrompt.recovery(
        task: task, run: run, contract: "contract", approvedInstructions: [])
    XCTAssertFalse(prompt.contains("message-0"))
    XCTAssertTrue(prompt.contains("message-44"))
}
```

Implement `AgentTaskPrompt` as a pure enum with these exact signatures:

```swift
public enum AgentTaskPrompt {
    public static func firstTurn(task: MustardTask, run: AgentRun, contract: String,
        approvedInstructions: [String]) -> String
    public static func resume(run: AgentRun, latestHumanMessage: String,
        contractReminder: String, approvedInstructions: [String]) -> String
    public static func recovery(task: MustardTask, run: AgentRun, contract: String,
        approvedInstructions: [String]) -> String
}
```

First turn includes contract, task UID/title/notes/action/project/source context and
approved instructions. Resume includes only the new human message, compact safety/output
reminder, and approved instructions because the provider session already has prior turns.
Recovery includes full task context plus only the latest 40 ordered durable messages.

```bash
swift test --filter 'AgentTurnContractTests|AgentTaskPromptTests'
```

Expected: all tests pass and the resource loads from `Bundle.module`.

- [ ] **Step 6: Commit the turn contract**

```bash
git add Package.swift Sources/MustardKit/Agent/AgentTurnContract.swift Sources/MustardKit/Agent/AgentTaskPrompt.swift Sources/MustardKit/Agent/Prompts/MustardAgentContract.md Tests/MustardTests/AgentTurnContractTests.swift Tests/MustardTests/AgentTaskPromptTests.swift
git commit -m "feat(agent): define delegated turn contract" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 4: Add pure task selection, routing, and transition decisions

**Files:**
- Create: `Sources/MustardKit/Logic/AgentTaskQueue.swift`
- Create: `Sources/MustardKit/Logic/AgentTaskTransition.swift`
- Create: `Tests/MustardTests/AgentTaskQueueTests.swift`
- Create: `Tests/MustardTests/AgentTaskTransitionTests.swift`

- [ ] **Step 1: Write failing queue/routing tests**

```swift
final class AgentTaskQueueTests: XCTestCase {
    private func task(_ title: String, stage: TaskStage, priority: TaskPriority = .normal,
                      created: TimeInterval) -> MustardTask {
        let task = MustardTask(title: title, owner: .agent)
        task.stage = stage; task.priority = priority
        task.createdAt = Date(timeIntervalSince1970: created)
        return task
    }

    func test_nextRunnable_prefersPriorityThenAge_andSkipsNeedsInput() {
        let waiting = task("waiting", stage: .needsInput, priority: .urgent, created: 1)
        let old = task("old", stage: .queued, priority: .normal, created: 2)
        let urgent = task("urgent", stage: .forAgent, priority: .urgent, created: 3)
        XCTAssertEqual(AgentTaskQueue.nextRunnable([waiting, old, urgent])?.title, "urgent")
    }

    func test_route_matchesTaskAreaToEnabledSource() {
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "DL", area: area)
        let task = MustardTask(title: "x", owner: .agent); task.list = list
        let settings = SourceSettings(sources: [
            SourceConfig(id: .vault, project: "DL-Knowledge-Base", enabled: true,
                         intervalHours: 1, workingDirectory: "/kb/DL")
        ], state: [])
        XCTAssertEqual(AgentTaskQueue.route(task, settings: settings)?.workingDirectory, "/kb/DL")
    }
}
```

- [ ] **Step 2: Write the failing transition matrix test**

```swift
func test_transitionMatrix() {
    XCTAssertEqual(AgentTaskTransition.decision(for: .needsInput),
                   .init(taskStage: .needsInput, runState: .needsInput, releasesSlot: true))
    XCTAssertEqual(AgentTaskTransition.decision(for: .completed),
                   .init(taskStage: .needsReview, runState: .completed, releasesSlot: true))
    XCTAssertEqual(AgentTaskTransition.decision(for: .requiresConnectedWorker),
                   .init(taskStage: .queued, runState: .queued, releasesSlot: true,
                         requiresConnectedWorker: true))
}
```

- [ ] **Step 3: Run tests and verify the pure units are missing**

```bash
swift test --filter 'AgentTaskQueueTests|AgentTaskTransitionTests'
```

Expected: compilation fails for missing units.

- [ ] **Step 4: Implement deterministic queue and route selection**

`AgentTaskQueue.nextRunnable` must:

```swift
let runnable = tasks.filter {
    $0.owner == .agent && ($0.stage == .forAgent || $0.stage == .queued) && !$0.isBlocked
}
let rank: [TaskPriority: Int] = [.urgent: 0, .high: 1, .normal: 2, .low: 3]
return runnable.sorted {
    let left = rank[$0.priority] ?? 2, right = rank[$1.priority] ?? 2
    return left == right ? $0.createdAt < $1.createdAt : left < right
}.first
```

`route` must match `task.list?.area?.name` against
`AreaMapping.areaName(forProject:)`, require an enabled source and non-empty working
directory, and return this value type:

```swift
public struct AgentTaskRoute: Equatable, Sendable {
    public let project: String
    public let workingDirectory: String
}
```

- [ ] **Step 5: Implement the transition decision value**

```swift
public struct AgentTransitionDecision: Equatable {
    public let taskStage: TaskStage
    public let runState: AgentRunState
    public let releasesSlot: Bool
    public let requiresConnectedWorker: Bool

    public init(taskStage: TaskStage, runState: AgentRunState, releasesSlot: Bool,
                requiresConnectedWorker: Bool = false) {
        self.taskStage = taskStage; self.runState = runState
        self.releasesSlot = releasesSlot
        self.requiresConnectedWorker = requiresConnectedWorker
    }
}
```

Map outcomes exactly as the test requires; `failed` remains at `.queued` with run state
`.failed`, and `cancelled` returns to `.planned` with run state `.cancelled`.

- [ ] **Step 6: Run the pure tests and commit**

```bash
swift test --filter 'AgentTaskQueueTests|AgentTaskTransitionTests'
git add Sources/MustardKit/Logic/AgentTaskQueue.swift Sources/MustardKit/Logic/AgentTaskTransition.swift Tests/MustardTests/AgentTaskQueueTests.swift Tests/MustardTests/AgentTaskTransitionTests.swift
git commit -m "feat(agent): add task scheduling decisions" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 5: Build the provider-neutral runtime and resumable Claude adapter

**Files:**
- Create: `Sources/MustardKit/Agent/AgentRuntime.swift`
- Create: `Sources/MustardKit/Agent/ClaudeTaskRuntime.swift`
- Modify: `Sources/MustardKit/Agent/ClaudeRunner.swift`
- Create: `Tests/MustardTests/ClaudeTaskRuntimeTests.swift`
- Modify: `Tests/MustardTests/ClaudeRunnerTests.swift`

- [ ] **Step 1: Write failing start/resume argument tests using the stub binary**

The stub writes all arguments to a test-owned file and returns Claude's outer JSON with
an inner contract result. Assert:

```swift
func test_start_usesChosenSessionAndSchema() async throws {
    let response = await runtime.start(.init(
        sessionID: "11111111-1111-1111-1111-111111111111",
        prompt: "do it", workingDirectory: "/tmp"))
    XCTAssertEqual(response.result?.outcome, .completed)
    let args = try String(contentsOf: argsFile, encoding: .utf8)
    XCTAssertTrue(args.contains("--session-id"))
    XCTAssertTrue(args.contains("11111111-1111-1111-1111-111111111111"))
    XCTAssertTrue(args.contains("--json-schema"))
}

func test_resume_usesResumeFlagAndSameSession() async throws {
    _ = await runtime.resume(.init(
        sessionID: "11111111-1111-1111-1111-111111111111",
        prompt: "version 2.21", workingDirectory: "/tmp"))
    let args = try String(contentsOf: argsFile, encoding: .utf8)
    XCTAssertTrue(args.contains("--resume"))
    XCTAssertTrue(args.contains("11111111-1111-1111-1111-111111111111"))
}
```

Also test that an outer CLI error maps to `.authenticationRequired` when text contains
`401`, `not logged in`, or `authentication`, and to `.rateLimited` when the existing
rate-limit detector fires. Map `No conversation found`, `session not found`, and
`unknown session` to `.sessionMissing`. Test `health()` against a stub response for
`claude auth status --json` and assert it returns `.available` on exit 0.

- [ ] **Step 2: Run the new runtime tests and verify the types are missing**

```bash
swift test --filter ClaudeTaskRuntimeTests
```

Expected: compilation fails for missing runtime types.

- [ ] **Step 3: Define the runtime API**

Create `AgentRuntime.swift`:

```swift
import Foundation

public struct AgentRuntimeRequest: Sendable {
    public let sessionID: String
    public let prompt: String
    public let workingDirectory: String
    public init(sessionID: String, prompt: String, workingDirectory: String) {
        self.sessionID = sessionID; self.prompt = prompt
        self.workingDirectory = workingDirectory
    }
}

public enum AgentRuntimeFailure: Equatable, Sendable {
    case authenticationRequired(String)
    case rateLimited(String)
    case timedOut(String)
    case sessionMissing(String)
    case malformedOutput(String)
    case process(String)
}

public enum AgentRuntimeHealth: Equatable, Sendable {
    case available
    case authenticationRequired(String)
    case unavailable(String)
}

public struct AgentRuntimeResponse: Equatable, Sendable {
    public let result: AgentTurnResult?
    public let failure: AgentRuntimeFailure?
}

public protocol AgentRuntime: Sendable {
    func start(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse
    func resume(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse
    func cancel() async
    func health() async -> AgentRuntimeHealth
}
```

- [ ] **Step 4: Refactor process spawning without breaking vault sweeps**

In `ClaudeRunner`, introduce:

```swift
public struct ClaudeInvocation: Sendable {
    public let id: UUID
    public let arguments: [String]
    public let workingDirectory: String
}

public typealias ClaudeInvoke = @Sendable (ClaudeInvocation) async -> ClaudeResult
```

Move the existing environment cleaning, closed stdin, concurrent pipe draining, timeout,
outer `{result,is_error}` parsing, and kill logic behind `ClaudeRunner.invoke`. Rebuild the
existing `ClaudeRunner.run` as:

```swift
public static let run: ClaudeRun = { prompt, cwd in
    await invoke(.init(id: UUID(), arguments: ["-p", prompt, "--output-format", "json"],
                       workingDirectory: cwd))
}
```

Keep a lock-protected `[UUID: Process]` registry inside `ClaudeRunner`. Register after
`process.run`, remove after exit, and expose `ClaudeRunner.cancel(_ id: UUID)` to terminate
only that process. Existing sweeps use throwaway IDs and never call cancel.

All existing `ClaudeRunnerTests` must remain green before adding the session adapter.

- [ ] **Step 5: Implement `ClaudeTaskRuntime`**

Implement `ClaudeTaskRuntime` as an actor. Inject `ClaudeInvoke` and an invocation-cancel
closure in the initializer; store only the current invocation UUID. `start` uses:

```swift
["-p", prompt,
 "--session-id", sessionID,
 "--output-format", "json",
 "--json-schema", AgentTurnContract.jsonSchema]
```

`resume` replaces `--session-id` with `--resume` and the same ID. Decode the outer
Claude result using the existing runner, then decode its `text` with
`AgentTurnContract.decode`. Treat `unparsed == true` as malformed output. Keep a
`cancel()` passes the stored UUID to the injected cancellation closure. Clear the UUID
after every completed invocation so a later cancel cannot kill an unrelated process.
`health()` invokes `["auth", "status", "--json"]`; a successful exit is `.available`,
authentication text is `.authenticationRequired`, and any other failure is `.unavailable`.

- [ ] **Step 6: Run runtime regression tests**

```bash
swift test --filter 'ClaudeRunnerTests|ClaudeTaskRuntimeTests|AgentTurnContractTests'
```

Expected: all tests pass, including large stdout/stderr and timeout regressions.

- [ ] **Step 7: Commit the runtime boundary**

```bash
git add Sources/MustardKit/Agent/AgentRuntime.swift Sources/MustardKit/Agent/ClaudeTaskRuntime.swift Sources/MustardKit/Agent/ClaudeRunner.swift Tests/MustardTests/ClaudeTaskRuntimeTests.swift Tests/MustardTests/ClaudeRunnerTests.swift
git commit -m "feat(agent): add resumable Claude runtime" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 6: Implement the serial task coordinator

**Files:**
- Create: `Sources/MustardKit/Agent/AgentTaskCoordinator.swift`
- Create: `Tests/MustardTests/AgentTaskCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests with a scripted runtime**

Define a test actor implementing `AgentRuntime` that records requests and pops scripted
responses. Cover these independent tests:

Use explicit test helpers so the shorthand below is defined:

```swift
extension AgentRuntimeResponse {
    static func completed(_ summary: String) -> Self {
        .init(result: .init(outcome: .completed, message: summary, questions: [],
            summary: summary, artifacts: [], retryDisposition: .none,
            errorCategory: nil, connectedCapability: nil), failure: nil)
    }
    static func question(_ text: String) -> Self {
        .init(result: .init(outcome: .needsInput, message: text, questions: [text],
            summary: "", artifacts: [], retryDisposition: .none,
            errorCategory: nil, connectedCapability: nil), failure: nil)
    }
}
```

```swift
@MainActor
func test_runNext_completesSimpleTaskIntoReview() async throws {
    let (coordinator, context, runtime) = try fixture(results: [.completed("Done")])
    let task = routedTask(stage: .forAgent); context.insert(task)
    await coordinator.runNext(settings: settings)
    XCTAssertEqual(task.stage, .needsReview)
    XCTAssertEqual(task.agentRun?.state, .completed)
    XCTAssertEqual(task.agentRun?.orderedMessages.last?.kind, .result)
    XCTAssertEqual(await runtime.startCount, 1)
}

@MainActor
func test_questionReleasesSlot_thenNextTaskRuns() async throws {
    let (coordinator, context, _) = try fixture(results: [.question("Which version?"), .completed("Other done")])
    let first = routedTask(title: "Prep release", stage: .forAgent, created: 1)
    let second = routedTask(title: "Other", stage: .forAgent, created: 2)
    context.insert(first); context.insert(second)
    await coordinator.runNext(settings: settings)
    XCTAssertEqual(first.stage, .needsInput)
    await coordinator.runNext(settings: settings)
    XCTAssertEqual(second.stage, .needsReview)
}

@MainActor
func test_replyRequeuesAndResumeUsesSameSession() async throws {
    let (coordinator, context, runtime) = try fixture(results: [.question("Which version?"), .completed("Prepared")])
    let task = routedTask(stage: .forAgent); context.insert(task)
    await coordinator.runNext(settings: settings)
    let session = try XCTUnwrap(task.agentRun?.providerSessionID)
    coordinator.reply(to: task, text: "2.21.0")
    XCTAssertEqual(task.stage, .queued)
    await coordinator.runNext(settings: settings)
    XCTAssertEqual(await runtime.resumedSessionIDs, [session])
    XCTAssertEqual(task.stage, .needsReview)
}
```

Also cover malformed output, missing route, connected fallback, and a second `runNext`
call while `isRunning == true` doing nothing.

- [ ] **Step 2: Run the coordinator tests and verify the type is missing**

```bash
swift test --filter AgentTaskCoordinatorTests
```

Expected: compilation fails for missing coordinator.

- [ ] **Step 3: Implement `AgentTaskCoordinator` state and message helpers**

Use this public surface:

```swift
@MainActor @Observable
public final class AgentTaskCoordinator {
    public private(set) var isRunning = false
    public private(set) var activeTitle: String?
    public private(set) var authenticationRequired = false
    public private(set) var lastError: String?

    public init(context: ModelContext, runtime: any AgentRuntime = ClaudeTaskRuntime())
    public func runNext(settings: SourceSettings, now: Date = .now) async
    public func reply(to task: MustardTask, text: String, now: Date = .now)
    public func requestChanges(_ task: MustardTask, feedback: String, now: Date = .now)
    public func accept(_ task: MustardTask, now: Date = .now)
    public func takeBack(_ task: MustardTask, now: Date = .now)
    public func cancelActive()
    public func retryAuthentication() async
    public func reconcileInterruptedRuns(now: Date = .now)
}
```

`append` assigns `sequence = (run.messages?.map(\.sequence).max() ?? -1) + 1`, inserts
the message into the context, and updates `lastActivityAt`.

- [ ] **Step 4: Implement one-turn orchestration**

`runNext` must guard `!isRunning && !authenticationRequired`, fetch tasks, call the pure
queue and route functions, ensure an `AgentRun`, persist `.inProgress/.running` plus a
system progress message, then call `start` when `providerSessionID` was just allocated or
`resume` otherwise.

Before the runtime call, load `AgentTurnContract.workerContract()` and build the prompt
through `AgentTaskPrompt.firstTurn` or `.resume`. Resolve and persist the run's project and
working directory from `AgentTaskQueue.route`. Generate the provider session UUID before
the first call so a crash never leaves an unidentifiable session.

Apply the pure transition decision and append:

- question message for `needs_input`
- result message plus task links for `completed`
- error message for `failed`
- recovery/progress message for connected fallback

Use `defer` to release `isRunning`/`activeTitle`. Authentication failures set the global
pause flag and restore the task/run to queued without consuming the rest of the queue.
For `.sessionMissing`, allocate a replacement UUID, append a recovery message, build
`AgentTaskPrompt.recovery`, and perform exactly one `start` attempt; do not recurse or
retry a second lost session in the same turn.

`retryAuthentication()` calls `runtime.health()`. Clear the pause/banner only for
`.available`; otherwise preserve the returned message.

- [ ] **Step 5: Implement reply and review commands**

`reply` and `requestChanges` trim whitespace, reject empty text, append the correct human
message kind, set task/run to queued, and leave the provider session ID unchanged.
`accept` calls `TaskCompletion.complete`; `takeBack` sets owner `.me`, stage `.planned`,
and run `.cancelled` while preserving messages.

- [ ] **Step 6: Run coordinator tests**

```bash
swift test --filter 'AgentTaskCoordinatorTests|AgentTaskQueueTests|AgentTaskTransitionTests'
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit the coordinator**

```bash
git add Sources/MustardKit/Agent/AgentTaskCoordinator.swift Tests/MustardTests/AgentTaskCoordinatorTests.swift
git commit -m "feat(agent): coordinate resumable task turns" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 7: Create runs at delegation and wire automatic pickup

**Files:**
- Modify: `Sources/MustardKit/Agent/AgentService.swift`
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `Tests/MustardTests/AgentTests.swift`
- Modify: `Tests/MustardTests/AgentAreaStampingTests.swift`

- [ ] **Step 1: Extend delegation tests to require a durable initial conversation**

After `service.delegate(task)`, assert:

```swift
let run = try XCTUnwrap(task.agentRun)
XCTAssertEqual(run.state, .queued)
XCTAssertEqual(run.orderedMessages.map(\.kind), [.delegation])
XCTAssertEqual(run.orderedMessages.first?.content, task.title)
```

For an area-less rejected delegation, assert `task.agentRun == nil`.

- [ ] **Step 2: Run the focused test and verify delegation lacks a run**

```bash
swift test --filter 'AgentTests/test_delegate|AgentAreaStampingTests'
```

Expected: the new run assertion fails.

- [ ] **Step 3: Create the run and first message only after the area gate succeeds**

At the end of `AgentService.delegate`:

```swift
let run = task.agentRun ?? AgentRun(task: task)
if task.agentRun == nil {
    task.agentRun = run
    context.insert(run)
    let body = task.notes.isEmpty ? task.title : "\(task.title)\n\n\(task.notes)"
    let message = AgentMessage(run: run, sequence: 0, role: .human,
                               kind: .delegation, content: body)
    context.insert(message)
}
run.state = .queued
```

Do not resolve the route here; the coordinator uses current source settings on pickup so
configuration changes before execution are respected.

- [ ] **Step 4: Own and inject the coordinator in `MustardApp`**

Add `@State private var taskAgent: AgentTaskCoordinator`, initialize it with the same
main context, and inject `.environment(taskAgent)` into Root, Hover, and Notch trees.
At task startup call `taskAgent.reconcileInterruptedRuns()` once.

Add a separate delegated-task loop in the root `.task` so pickup is not delayed by the
60-second source cadence:

```swift
Task {
    while !Task.isCancelled {
        if !agent.isSweeping && !agent.isExecuting {
            await taskAgent.runNext(settings: SourceSettingsStore.loadOrMigrate())
        }
        try? await Task.sleep(for: .seconds(2))
    }
}
```

Also add `!taskAgent.isRunning` to the existing source-sweep execution guard so a sweep
and delegated turn never consume the subscription concurrently. The coordinator's own
guard enforces one active delegated turn.

- [ ] **Step 5: Run delegation and coordinator tests**

```bash
swift test --filter 'AgentTests/test_delegate|AgentTaskCoordinatorTests|AgentAreaStampingTests'
swift build
```

Expected: tests pass and the app compiles with the new environment dependency.

- [ ] **Step 6: Commit automatic pickup wiring**

```bash
git add Sources/MustardKit/Agent/AgentService.swift Sources/Mustard/MustardApp.swift Tests/MustardTests/AgentTests.swift Tests/MustardTests/AgentAreaStampingTests.swift
git commit -m "feat(agent): start delegated tasks automatically" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 8: Add recovery and duplicate-safe retry policy

**Files:**
- Create: `Sources/MustardKit/Logic/AgentRetryPolicy.swift`
- Create: `Tests/MustardTests/AgentRetryPolicyTests.swift`
- Modify: `Sources/MustardKit/Agent/AgentTaskCoordinator.swift`
- Modify: `Tests/MustardTests/AgentTaskCoordinatorTests.swift`

- [ ] **Step 1: Write failing retry-policy tests**

```swift
func test_authenticationPausesGlobally_withoutConsumingTask() {
    XCTAssertEqual(AgentRetryPolicy.action(for: .authenticationRequired("401"),
                                           action: .vaultNote), .pauseRuntime)
}

func test_safeLocalFailureRequeuesWithBackoff() {
    XCTAssertEqual(AgentRetryPolicy.action(for: .process("temporary"),
                                           action: .vaultNote), .retryAfter(seconds: 60))
}

func test_externalCreationWithUnknownResultRequiresReview() {
    XCTAssertEqual(AgentRetryPolicy.action(for: .timedOut("timeout"),
                                           action: .ticket), .completionUncertain)
}
```

- [ ] **Step 2: Run and confirm the policy is missing**

```bash
swift test --filter AgentRetryPolicyTests
```

Expected: compilation fails for missing `AgentRetryPolicy`.

- [ ] **Step 3: Implement explicit retry actions**

```swift
public enum AgentRetryAction: Equatable {
    case pauseRuntime
    case retryAfter(seconds: TimeInterval)
    case completionUncertain
    case fail
}
```

Use `.completionUncertain` for ticket/email-draft/Slack-draft timeouts or process exits
after work began; use bounded 60/300/900-second backoff for safe actions based on attempt
count; cap at three automatic retries, then `.fail`.

- [ ] **Step 4: Apply the policy in coordinator failure handling**

Persist a `nextAttemptAt: Date?` on `AgentRun`; update `AgentTaskQueue.nextRunnable` to
skip runs whose next attempt is in the future. On uncertain completion, set the task to
`.needsReview` and append:

```text
Completion uncertain — check whether the external artifact exists before requesting a retry.
```

`reconcileInterruptedRuns` changes `.running` runs to `.interrupted`; local actions return
to queued, while external creation moves to uncertain review. Record a recovery message in
both cases.

- [ ] **Step 5: Run policy and coordinator recovery tests**

```bash
swift test --filter 'AgentRetryPolicyTests|AgentTaskCoordinatorTests'
```

Expected: all selected tests pass with pinned `now` values.

- [ ] **Step 6: Commit recovery policy**

```bash
git add Sources/MustardKit/Logic/AgentRetryPolicy.swift Sources/MustardKit/Models/AgentRun.swift Sources/MustardKit/Logic/AgentTaskQueue.swift Sources/MustardKit/Agent/AgentTaskCoordinator.swift Tests/MustardTests/AgentRetryPolicyTests.swift Tests/MustardTests/AgentTaskCoordinatorTests.swift
git commit -m "feat(agent): recover interrupted task runs" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 9: Restrict the bridge to explicit connected fallback and normalize results

**Files:**
- Modify: `Sources/MustardKit/Logic/BridgeExport.swift`
- Modify: `Sources/MustardKit/Logic/BridgeIngest.swift`
- Modify: `Sources/MustardKit/Agent/AgentService.swift`
- Modify: `Tests/MustardTests/BridgeExportTests.swift`
- Modify: `Tests/MustardTests/BridgeIngestTests.swift`
- Modify: `Tests/MustardTests/AgentBridgeServiceTests.swift`

- [ ] **Step 1: Write the duplicate-prevention bridge test**

```swift
func test_defaultQueuedTask_isNotExported_withoutConnectedFallbackFlag() {
    let task = task(.queued, uid: "u1", action: .ticket)
    task.agentRun = AgentRun(task: task)
    task.agentRun?.requiresConnectedWorker = false
    let plan = BridgeExport.plan(tasks: [task], route: route,
                                 liveOutboxUIDs: [:], now: now)
    XCTAssertTrue(plan.writes.isEmpty)
}

func test_connectedFallbackTask_isExported() {
    let task = task(.queued, uid: "u1", action: .ticket)
    task.agentRun = AgentRun(task: task)
    task.agentRun?.requiresConnectedWorker = true
    let plan = BridgeExport.plan(tasks: [task], route: route,
                                 liveOutboxUIDs: [:], now: now)
    XCTAssertEqual(plan.writes.map(\.order.uid), ["u1"])
}
```

- [ ] **Step 2: Run the bridge tests and verify ordinary tasks still export**

```bash
swift test --filter 'BridgeExportTests|AgentBridgeServiceTests'
```

Expected: the default-path exclusion test fails.

- [ ] **Step 3: Gate export on `requiresConnectedWorker`**

In `BridgeExport.plan`, retain active/cancel bookkeeping but write only when:

```swift
guard t.agentRun?.requiresConnectedWorker == true else { continue }
```

Existing historical tasks without an `AgentRun` must remain exportable only when they
were already live in the outbox; do not generate new bridge orders for them. This avoids
the default coordinator and bridge both claiming the same task.

- [ ] **Step 4: Normalize bridge results into messages**

After `BridgeIngest.apply` succeeds, `AgentService.ingestAgentResults` must update the
linked run when present:

- execute done → append `.result`, set run `.completed`, clear fallback flag
- prep done → append `.progress`, set run `.queued`
- declined → append `.error`, set run `.cancelled`
- failed → append `.error`, keep fallback flag for explicit retry

Reuse the same sequence allocation rule as the coordinator; extract it to an internal
`AgentConversation.append` helper if that prevents duplicated persistence code.

- [ ] **Step 5: Run all bridge tests**

```bash
swift test --filter 'BridgeProtocolTests|BridgeExportTests|BridgeIngestTests|FileBridgeIOTests|AgentBridgeServiceTests'
```

Expected: all bridge tests pass and no default task is exported.

- [ ] **Step 6: Commit fallback isolation**

```bash
git add Sources/MustardKit/Logic/BridgeExport.swift Sources/MustardKit/Logic/BridgeIngest.swift Sources/MustardKit/Agent/AgentService.swift Tests/MustardTests/BridgeExportTests.swift Tests/MustardTests/BridgeIngestTests.swift Tests/MustardTests/AgentBridgeServiceTests.swift
git commit -m "refactor(agent): isolate connected worker fallback" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 10: Render Needs You and runtime state across the board

**Files:**
- Modify: `Sources/MustardKit/Views/BoardView.swift`
- Modify: `Sources/MustardKit/Views/MustardBoardCard.swift`
- Modify: `Sources/MustardKit/Views/RootView.swift`
- Modify: `Sources/MustardKit/Views/NotchSurface.swift`
- Modify: `Sources/MustardKit/Views/TimelineRow.swift`
- Modify: `Sources/MustardKit/Views/WeekView.swift`
- Modify: `Sources/MustardMobile/MobileBoardView.swift`
- Modify: `Sources/MustardMobile/MobileTaskSheet.swift`

- [ ] **Step 1: Update exhaustive view switches and labels**

In board/card stage switches, render:

```swift
case .inProgress:
    return ("Agent working…", Theme.Palette.agentText, Theme.Palette.agentTintLight)
case .needsInput:
    return ("Your answer needed", Theme.Palette.warnText, Theme.Palette.warnTintSoft)
```

The review-focus help/caption must say three attention columns rather than two gates.
Keep the left agent-purple accent; use amber only for the Needs You status pill, not the
whole card.

- [ ] **Step 2: Keep all delegation actions on the existing `AgentService.delegate` path**

Verify Timeline, Week, Board, Task Detail, and card owner-toggle actions all call
`agent.delegate(task)` rather than directly assigning `.forAgent`. The service now creates
the durable run; direct stage mutation would create an agent task without a conversation.

- [ ] **Step 3: Update mobile read-only/triage surfaces for the new enum case**

Mobile never runs the CLI. It must render Needs You, allow Take Back, and allow typing an
answer only after CloudKit sync exists; for this MVP show the question and the text
“Reply on Mac to resume.” This prevents an exhaustive-switch build failure without
inventing unsupported mobile execution.

- [ ] **Step 4: Build both targets**

```bash
swift build
xcodegen generate
xcodebuild -project MustardMobile.xcodeproj -scheme MustardMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: macOS and iOS targets compile. Do not claim visual correctness.

- [ ] **Step 5: Commit board state presentation**

```bash
git add Sources/MustardKit/Views Sources/MustardMobile
git commit -m "feat(agent): surface working and needs-you states" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 11: Add the task conversation, reply, and review UI

**Files:**
- Create: `Sources/MustardKit/Views/AgentConversationView.swift`
- Modify: `Sources/MustardKit/Views/TaskDetailSheet.swift`
- Modify: `Sources/MustardKit/Views/AgentConsoleView.swift`
- Modify: `Sources/MustardKit/Views/TaskDetailDrawer.swift`
- Modify: `Sources/MustardKit/Logic/AgentInbox.swift`
- Test: `Tests/MustardTests/AgentInboxTests.swift`

- [ ] **Step 1: Extend the pure Agent inbox grouping**

Add and test:

```swift
public struct AgentAttention {
    public let questions: [MustardTask]
    public let reviews: [MustardTask]
}

public static func attention(_ tasks: [MustardTask]) -> AgentAttention {
    AgentAttention(
        questions: tasks.filter { $0.stage == .needsInput }.sorted { $0.createdAt < $1.createdAt },
        reviews: tasks.filter { $0.stage == .needsReview }.sorted { $0.createdAt < $1.createdAt })
}
```

Test exact ordering and exclusion of queued/in-progress tasks.

- [ ] **Step 2: Build a focused reusable conversation view**

`AgentConversationView` takes `@Bindable var task`, reads
`task.agentRun?.orderedMessages`, and receives closures for reply, request changes,
accept, and take back. It renders:

- system rows in tertiary type
- human bubbles in accent tint
- agent messages in agent tint
- links using `Link`
- pinned reply composer only in `.needsInput`
- feedback composer plus Accept/Take Back only in `.needsReview`
- “Connected worker required” action when the run flag is true

Use `Theme` tokens only. Disable reply/revision buttons for whitespace-only text and
clear local text only after dispatch.

- [ ] **Step 3: Mount the conversation in Task Detail**

Inject `@Environment(AgentTaskCoordinator.self)` in `TaskDetailSheet`. Place
`AgentConversationView` after the task body and before links/subtasks when `agentRun != nil`.
Replace direct Needs Review moves with:

```swift
taskAgent.requestChanges(task, feedback: feedback)
taskAgent.accept(task)
taskAgent.takeBack(task)
taskAgent.reply(to: task, text: reply)
```

Keep delete and ordinary task editing behavior unchanged.

- [ ] **Step 4: Add the unified attention queue to Agent Console**

Query `MustardTask` alongside recommendations. Above recommendations, render two compact
sections from `AgentInbox.attention`: **Needs You** then **Needs Review**. Selecting a task
opens the existing docked `TaskDetailDrawer`; do not duplicate the conversation UI in the
console. When `taskAgent.authenticationRequired` is true, show one banner with
`claude auth login` instructions and a **Retry** button wired to
`taskAgent.retryAuthentication()`; do not repeat the same failure on every task row.

- [ ] **Step 5: Build and perform the required eye check**

```bash
swift test --filter AgentInboxTests
swift build
./build-app.sh
open build/Mustard.app
```

Ask Leon to verify: question composer placement, readable timeline, review artifacts,
and that the Agent queue opens the correct task. State only that it builds and runs.

- [ ] **Step 6: Commit the conversation and review surface**

```bash
git add Sources/MustardKit/Views/AgentConversationView.swift Sources/MustardKit/Views/TaskDetailSheet.swift Sources/MustardKit/Views/AgentConsoleView.swift Sources/MustardKit/Views/TaskDetailDrawer.swift Sources/MustardKit/Logic/AgentInbox.swift Tests/MustardTests/AgentInboxTests.swift
git commit -m "feat(agent): add task conversation and review queue" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 12: Update previews, operational docs, and verify the MVP

**Files:**
- Modify: `Sources/MustardKit/PreviewData.swift`
- Modify: `CLAUDE.md`
- Modify: `docs/architecture.md`
- Modify: `docs/build-order.md`
- Modify: `docs/agent-bridge-contract.md`
- Modify: `docs/specs/2026-07-13-agent-task-sessions-design.md`

- [ ] **Step 1: Add representative preview conversations**

Create one Needs You “Prep release” sample with a question and one Needs Review Shortcut
sample with a verified link. Insert their runs/messages into the preview context so Board,
Agent Console, and Task Detail can be inspected without live CLI work.

- [ ] **Step 2: Replace stale architecture documentation**

Document the default lifecycle exactly as:

```text
For Agent/Queued → AgentTaskCoordinator → Claude start/resume
  → Needs You (reply requeues) | Needs Review (accept/revise/take back)
```

State that bridge export occurs only for `requiresConnectedWorker == true`. Remove claims
that all board hand-offs require manual `drain-agent-queue`, and remove remaining active
architecture claims that output review uses `OutputCard`.

- [ ] **Step 3: Mark the core slice built only after verification**

Add an F-number/build-order entry naming the delivered core and list approved learning,
Codex runtime, parallelism, live streaming, and automatic connected launch as remaining
work. Change the design spec status to **Core implemented; learning follow-on planned**.

- [ ] **Step 4: Run focused then full verification**

```bash
swift test --filter 'AgentRunModelTests|AgentTaskQueueTests|AgentTaskTransitionTests|AgentTurnContractTests|ClaudeTaskRuntimeTests|AgentTaskCoordinatorTests|AgentRetryPolicyTests|AgentInboxTests|BridgeExportTests|BridgeIngestTests'
swift test
swift build
./build-app.sh
```

Expected: every command exits 0. Record the actual test count in `CLAUDE.md`; do not copy
the historical count.

- [ ] **Step 5: Perform the end-to-end manual acceptance run**

Use safe test tasks in a test KB:

1. delegate a one-shot local summary and confirm automatic Needs Review
2. delegate “Prep release”, confirm Needs You, then delegate another task and see it finish
3. answer the release question and confirm the same session resumes
4. request changes and confirm the same conversation resumes
5. exercise connected fallback without creating a real external artifact
6. relaunch with a queued and Needs You task and confirm both persist

- [ ] **Step 6: Commit documentation and preview fixtures**

```bash
git add Sources/MustardKit/PreviewData.swift CLAUDE.md docs/architecture.md docs/build-order.md docs/agent-bridge-contract.md docs/specs/2026-07-13-agent-task-sessions-design.md
git commit -m "docs(agent): document automatic task sessions" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Final completion gate

Before claiming the core MVP is complete:

- all new and existing tests pass
- `swift build` passes
- the packaged app launches
- Leon visually confirms the new native surfaces
- no ordinary delegated task is exported to the bridge
- a Needs You task releases the runner
- every completed task lands in Needs Review
- the untracked/user-owned `AGENTS.md` is not added or modified unless Leon separately
  approves it
- all implementation remains on its feature branch; do not merge to `main`, push, or
  create a ready-to-merge PR until Leon has completed thorough hands-on testing and gives
  explicit approval
