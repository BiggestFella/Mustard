# Approved Agent Learning Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn explicit and repeated review feedback into scoped, inspectable learning proposals that Leon approves before Mustard injects them into future relevant task sessions or applies reversible skill changes.

**Architecture:** Persist review evidence, learning proposals, and approved memories in SwiftData. Keep proposal eligibility and memory relevance pure; use `AgentLearningService` for persistence, inject selected memories through the existing `AgentTaskPrompt`, and isolate approved skill-file replacement behind snapshotting `SkillChangeIO`.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, Observation, Foundation file IO, XCTest.

---

## Dependency and scope

Execute this plan only after
`docs/superpowers/plans/2026-07-13-agent-task-sessions-core.md` is complete. It relies on
`AgentRun`, `AgentMessage`, `AgentTaskCoordinator`, `AgentTurnResult`, and
`AgentTaskPrompt` from that plan.

This plan does not add Codex, parallel execution, automatic trust graduation, semantic
embeddings, or silent skill edits. It implements deterministic scoped retrieval and an
approval gate first.

## File structure

### New files

| File | Responsibility |
|---|---|
| `Sources/MustardKit/Models/AgentReviewEvent.swift` | Durable accepted/revised/rejected evidence |
| `Sources/MustardKit/Models/LearningProposal.swift` | Pending/approved/rejected reusable improvement |
| `Sources/MustardKit/Models/AgentMemory.swift` | Enabled approved instruction at a specific scope |
| `Sources/MustardKit/Logic/LearningPolicy.swift` | Pure proposal eligibility and scope validation |
| `Sources/MustardKit/Logic/AgentMemorySelector.swift` | Pure relevant-memory ranking and dedupe |
| `Sources/MustardKit/Logic/SkillChangePlan.swift` | Validate allowed target and snapshot/write/undo operations |
| `Sources/MustardKit/Agent/AgentLearningService.swift` | Persist evidence, proposals, approvals, and memories |
| `Sources/MustardKit/Agent/SkillChangeIO.swift` | Injected file snapshot/replacement implementation |
| `Sources/MustardKit/Views/AgentLearningQueueView.swift` | Proposal approval/edit/reject and approved-memory management |
| `Tests/MustardTests/LearningModelTests.swift` | SwiftData relationships and defaults |
| `Tests/MustardTests/LearningPolicyTests.swift` | Explicit/repeated evidence eligibility |
| `Tests/MustardTests/AgentMemorySelectorTests.swift` | Scope matching, precedence, and dedupe |
| `Tests/MustardTests/AgentLearningServiceTests.swift` | Review-to-proposal-to-memory integration |
| `Tests/MustardTests/SkillChangePlanTests.swift` | Allowed path, snapshot, replacement, and undo plan |
| `Tests/MustardTests/FileSkillChangeIOTests.swift` | Atomic file operations in a temporary directory |

### Existing files changed

| File | Change |
|---|---|
| `Sources/MustardKit/Models/AgentRun.swift` | Add review-event relationship and skill/task-type metadata |
| `Sources/MustardKit/MustardContainer.swift` and `Sources/MustardKit/PreviewData.swift` | Register learning models |
| `Sources/MustardKit/Agent/AgentTurnContract.swift` | Decode optional structured learning candidates |
| `Sources/MustardKit/Agent/AgentTaskPrompt.swift` | Render selected approved memories compactly |
| `Sources/MustardKit/Agent/AgentTaskCoordinator.swift` | Record review outcomes and supply memories per turn |
| `Sources/Mustard/MustardApp.swift` | Own/inject `AgentLearningService` and skill IO |
| `Sources/MustardKit/Views/AgentConsoleView.swift` | Mount learning queue |
| `Sources/MustardKit/Views/AgentConversationView.swift` | Add “Remember this” affordance to review feedback |
| `Sources/MustardKit/Views/SettingsView.swift` | List/edit/disable/delete approved memories |
| `CLAUDE.md`, `docs/architecture.md`, `docs/build-order.md` | Document the approved learning loop |

## Task 1: Persist review evidence, proposals, and approved memories

**Files:**
- Create: `Sources/MustardKit/Models/AgentReviewEvent.swift`
- Create: `Sources/MustardKit/Models/LearningProposal.swift`
- Create: `Sources/MustardKit/Models/AgentMemory.swift`
- Modify: `Sources/MustardKit/Models/AgentRun.swift`
- Modify: `Sources/MustardKit/MustardContainer.swift`
- Modify: `Sources/MustardKit/PreviewData.swift`
- Create: `Tests/MustardTests/LearningModelTests.swift`
- Modify: test-local MustardTask schemas

- [ ] **Step 1: Write the failing model round-trip test**

```swift
import XCTest
import SwiftData
@testable import MustardKit

final class LearningModelTests: XCTestCase {
    @MainActor
    func test_reviewProposalAndMemoryRoundTrip() throws {
        let container = try ModelContainer(
            for: MustardTask.self, AgentRun.self, AgentMessage.self,
            AgentReviewEvent.self, LearningProposal.self, AgentMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let task = MustardTask(title: "Create Shortcut")
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL")
        let review = AgentReviewEvent(run: run, outcome: .revised,
            feedback: "Use Given/When/Then", candidateKey: "shortcut-acceptance-format")
        let proposal = LearningProposal(instruction: "Use Given/When/Then acceptance criteria",
            scope: .project, scopeKey: "DL", candidateKey: "shortcut-acceptance-format")
        proposal.evidenceUIDs = [review.uid]
        let memory = AgentMemory(instruction: proposal.instruction,
            scope: proposal.scope, scopeKey: proposal.scopeKey)
        context.insert(task); context.insert(run); context.insert(review)
        context.insert(proposal); context.insert(memory)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<LearningProposal>()).first?.status,
                       .pending)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentMemory>()).first?.scope,
                       .project)
        XCTAssertEqual(run.reviewEvents?.first?.outcome, .revised)
    }
}
```

- [ ] **Step 2: Run and confirm the models are missing**

```bash
swift test --filter LearningModelTests
```

Expected: compilation fails for the three missing models.

- [ ] **Step 3: Add the review evidence model**

```swift
public enum AgentReviewOutcome: String, Codable { case accepted, revised, rejected, takenBack }

@Model
public final class AgentReviewEvent {
    public var uid: String = UUID().uuidString
    public var outcomeRaw: String = AgentReviewOutcome.accepted.rawValue
    public var feedback: String = ""
    public var proposedOutput: String = ""
    public var acceptedOutput: String = ""
    public var candidateKey: String?
    public var candidateInstruction: String?
    public var explicitRemember: Bool = false
    public var project: String = ""
    public var taskType: String = ""
    public var skillName: String?
    public var actionTypeRaw: String?
    public var firstPass: Bool = true
    public var createdAt: Date = .now
    public var run: AgentRun?

    public var outcome: AgentReviewOutcome {
        get { AgentReviewOutcome(rawValue: outcomeRaw) ?? .accepted }
        set { outcomeRaw = newValue.rawValue }
    }
}
```

Provide an initializer matching the test. Add to `AgentRun`:

```swift
public var taskType: String = "general"
public var skillName: String?
public var latestLearningCandidatesJSON: String?
@Relationship(deleteRule: .cascade, inverse: \AgentReviewEvent.run)
public var reviewEvents: [AgentReviewEvent]? = []
```

- [ ] **Step 4: Add proposal and memory models with typed accessors**

```swift
public enum LearningScope: String, Codable, CaseIterable {
    case taskType, skill, project, global
}
public enum LearningProposalStatus: String, Codable { case pending, approved, rejected }
public enum LearningDestination: String, Codable { case memory, skillChange }

@Model
public final class LearningProposal {
    public var uid: String = UUID().uuidString
    public var instruction: String = ""
    public var scopeRaw: String = LearningScope.project.rawValue
    public var scopeKey: String = ""
    public var candidateKey: String = ""
    public var destinationRaw: String = LearningDestination.memory.rawValue
    public var statusRaw: String = LearningProposalStatus.pending.rawValue
    public var confidence: Double = 0.5
    public var evidenceUIDs: [String] = []
    public var targetSkillPath: String?
    public var replacementText: String?
    public var diffPreview: String?
    public var createdAt: Date = .now
    public var decidedAt: Date?
}

@Model
public final class AgentMemory {
    public var uid: String = UUID().uuidString
    public var instruction: String = ""
    public var scopeRaw: String = LearningScope.project.rawValue
    public var scopeKey: String = ""
    public var evidenceUIDs: [String] = []
    public var enabled: Bool = true
    public var version: Int = 1
    public var createdAt: Date = .now
    public var updatedAt: Date = .now
}
```

Add `scope`, `destination`, and `status` typed accessors to `LearningProposal`, plus this
initializer:

```swift
public init(instruction: String = "", scope: LearningScope = .project,
            scopeKey: String = "", candidateKey: String = "") {
    self.instruction = instruction; self.scopeRaw = scope.rawValue
    self.scopeKey = scopeKey; self.candidateKey = candidateKey
}
```

Add `scope` to `AgentMemory` and this initializer:

```swift
public init(instruction: String = "", scope: LearningScope = .project,
            scopeKey: String = "") {
    self.instruction = instruction; self.scopeRaw = scope.rawValue; self.scopeKey = scopeKey
}
```

Add the full `AgentReviewEvent` initializer used by the tests, assigning run/outcome,
feedback, candidate key/instruction, explicit remember, and timestamps. Every typed
accessor falls back to the conservative default (`pending`, `memory`, `project`).

- [ ] **Step 5: Register models in production, preview, and relevant tests**

Add `AgentReviewEvent.self, LearningProposal.self, AgentMemory.self` everywhere the full
Mustard task schema is constructed. Update the model test's insertion to individual
`context.insert(...)` calls if the compiler rejects existential `PersistentModel` arrays.

- [ ] **Step 6: Run and commit model persistence**

```bash
swift test --filter 'LearningModelTests|AgentRunModelTests|ModelTests'
git add Sources/MustardKit/Models Sources/MustardKit/MustardContainer.swift Sources/MustardKit/PreviewData.swift Tests/MustardTests
git commit -m "feat(agent): persist review learning evidence" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 2: Make proposal eligibility and scope deterministic

**Files:**
- Create: `Sources/MustardKit/Logic/LearningPolicy.swift`
- Create: `Tests/MustardTests/LearningPolicyTests.swift`

- [ ] **Step 1: Write failing eligibility tests**

```swift
func test_explicitRemember_isEligibleImmediately() {
    let event = evidence(key: "format", remember: true)
    XCTAssertEqual(LearningPolicy.proposal(from: event, history: [event])?.scope,
                   .project)
}

func test_oneImplicitCorrection_isNotEnough() {
    let event = evidence(key: "format", remember: false)
    XCTAssertNil(LearningPolicy.proposal(from: event, history: [event]))
}

func test_twoComparableCorrections_createOneProposal() {
    let first = evidence(key: "format", remember: false)
    let second = evidence(key: "format", remember: false)
    let draft = LearningPolicy.proposal(from: second, history: [first, second])
    XCTAssertEqual(draft?.candidateKey, "format")
    XCTAssertEqual(draft?.evidenceUIDs.count, 2)
}

func test_scopeRequiresKeyExceptGlobal() {
    XCTAssertFalse(LearningPolicy.valid(scope: .project, key: ""))
    XCTAssertTrue(LearningPolicy.valid(scope: .global, key: ""))
}
```

- [ ] **Step 2: Run and verify the policy is missing**

```bash
swift test --filter LearningPolicyTests
```

Expected: compilation fails for missing `LearningPolicy`.

- [ ] **Step 3: Implement a value-only proposal draft**

```swift
public struct LearningProposalDraft: Equatable {
    public let instruction: String
    public let scope: LearningScope
    public let scopeKey: String
    public let candidateKey: String
    public let evidenceUIDs: [String]
    public let confidence: Double
}
```

`proposal(from:history:)` must require non-empty `candidateKey` and
`candidateInstruction`, select history with the same key/project/taskType/skill scope,
and return when `explicitRemember` is true or at least two comparable events exist.
Confidence is `1.0` for explicit remember and `min(0.95, 0.6 + 0.1 * evidenceCount)` for
repeated evidence. Default scope precedence is skill, then taskType, then project, then
global only when the event explicitly nominates global scope.

- [ ] **Step 4: Run and commit the pure policy**

```bash
swift test --filter LearningPolicyTests
git add Sources/MustardKit/Logic/LearningPolicy.swift Tests/MustardTests/LearningPolicyTests.swift
git commit -m "feat(agent): derive evidence-backed learning proposals" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 3: Select only relevant approved memories

**Files:**
- Create: `Sources/MustardKit/Logic/AgentMemorySelector.swift`
- Create: `Tests/MustardTests/AgentMemorySelectorTests.swift`

- [ ] **Step 1: Write failing relevance and precedence tests**

```swift
func test_selectsMatchingScopes_narrowestFirst() {
    let all = [
        memory("global", .global, ""),
        memory("project", .project, "DL"),
        memory("type", .taskType, "ticket"),
        memory("skill", .skill, "dl-create-shortcut-story"),
        memory("other", .project, "SB")
    ]
    let result = AgentMemorySelector.select(all, context: .init(
        project: "DL", taskType: "ticket", skillName: "dl-create-shortcut-story"))
    XCTAssertEqual(result.map(\.instruction), ["skill", "type", "project", "global"])
}

func test_disabledAndDuplicateInstructionsAreRemoved() {
    let first = memory("Use bullets", .project, "DL")
    let duplicate = memory(" use   bullets ", .global, "")
    let disabled = memory("hidden", .project, "DL"); disabled.enabled = false
    XCTAssertEqual(AgentMemorySelector.select([first, duplicate, disabled],
        context: .init(project: "DL", taskType: "general", skillName: nil)).count, 1)
}
```

- [ ] **Step 2: Run and verify selector is missing**

```bash
swift test --filter AgentMemorySelectorTests
```

- [ ] **Step 3: Implement scope matching, stable ordering, and normalized dedupe**

Use this context:

```swift
public struct AgentMemoryContext: Equatable {
    public let project: String
    public let taskType: String
    public let skillName: String?
}
```

Rank `.skill = 0`, `.taskType = 1`, `.project = 2`, `.global = 3`; within a scope sort
by `updatedAt` descending. Normalize dedupe keys by trimming, lowercasing, and collapsing
whitespace. Return at most 12 memories to bound prompt growth.

- [ ] **Step 4: Run and commit the selector**

```bash
swift test --filter AgentMemorySelectorTests
git add Sources/MustardKit/Logic/AgentMemorySelector.swift Tests/MustardTests/AgentMemorySelectorTests.swift
git commit -m "feat(agent): retrieve scoped approved memories" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 4: Record reviews and promote approved memories

**Files:**
- Create: `Sources/MustardKit/Agent/AgentLearningService.swift`
- Create: `Tests/MustardTests/AgentLearningServiceTests.swift`
- Modify: `Sources/MustardKit/Agent/AgentTurnContract.swift`
- Modify: `Tests/MustardTests/AgentTurnContractTests.swift`

- [ ] **Step 1: Extend the turn contract with optional candidates**

Add:

```swift
public struct AgentLearningCandidate: Codable, Equatable, Sendable {
    public let key: String
    public let instruction: String
    public let suggestedScope: LearningScope
    public let suggestedScopeKey: String
    public let destination: LearningDestination
    public let targetSkillPath: String?
    public let replacementText: String?
    public let diffPreview: String?
}
```

Add `learningCandidates: [AgentLearningCandidate]?` to `AgentTurnResult`. Verify old JSON
without the key still decodes and a candidate round-trips.

- [ ] **Step 2: Write failing service tests**

```swift
@MainActor
func test_secondMatchingRevision_createsOnePendingProposal() throws {
    let (service, context, run) = try fixture()
    service.recordReview(run: run, outcome: .revised,
        feedback: "Use Given/When/Then", explicitRemember: false,
        candidate: candidate(key: "acceptance-format"))
    service.recordReview(run: run, outcome: .revised,
        feedback: "Use Given/When/Then", explicitRemember: false,
        candidate: candidate(key: "acceptance-format"))
    XCTAssertEqual(try context.fetch(FetchDescriptor<LearningProposal>()).count, 1)
}

@MainActor
func test_approveMemoryProposal_createsEnabledMemory() throws {
    let (service, context, _) = try fixture()
    let proposal = LearningProposal(instruction: "Use Given/When/Then",
        scope: .project, scopeKey: "DL", candidateKey: "acceptance-format")
    context.insert(proposal)
    try service.approve(proposal)
    let memory = try XCTUnwrap(context.fetch(FetchDescriptor<AgentMemory>()).first)
    XCTAssertTrue(memory.enabled)
    XCTAssertEqual(proposal.status, .approved)
}

@MainActor
func test_rejectProposal_createsNoMemory() throws {
    let (service, context, _) = try fixture()
    let proposal = LearningProposal(instruction: "x", scope: .project,
                                    scopeKey: "DL", candidateKey: "x")
    context.insert(proposal); service.reject(proposal)
    XCTAssertTrue(try context.fetch(FetchDescriptor<AgentMemory>()).isEmpty)
}
```

- [ ] **Step 3: Implement `AgentLearningService`**

Use this API:

```swift
@MainActor @Observable
public final class AgentLearningService {
    public init(context: ModelContext)
    public func recordReview(run: AgentRun, outcome: AgentReviewOutcome,
        feedback: String, explicitRemember: Bool,
        candidate: AgentLearningCandidate?, now: Date = .now)
    public func approve(_ proposal: LearningProposal, now: Date = .now) throws
    public func reject(_ proposal: LearningProposal, now: Date = .now)
    public func update(_ memory: AgentMemory, instruction: String, enabled: Bool, now: Date = .now)
    public func delete(_ memory: AgentMemory)
    public func selectedMemories(for run: AgentRun) -> [AgentMemory]
}
```

`recordReview` inserts `AgentReviewEvent`, asks `LearningPolicy` for a draft, and inserts
one pending proposal only when no pending/approved proposal already has the same
candidateKey/scope/scopeKey. `approve` creates `AgentMemory` for memory destinations;
for a skill-change destination it throws `LearningServiceError.skillChangesNotEnabled`
until Task 7 adds the injected file boundary.

- [ ] **Step 4: Run service and contract tests**

```bash
swift test --filter 'AgentTurnContractTests|AgentLearningServiceTests|LearningPolicyTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit review evidence orchestration**

```bash
git add Sources/MustardKit/Agent/AgentTurnContract.swift Sources/MustardKit/Agent/AgentLearningService.swift Tests/MustardTests/AgentTurnContractTests.swift Tests/MustardTests/AgentLearningServiceTests.swift
git commit -m "feat(agent): turn reviews into learning proposals" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 5: Inject approved learning into future task prompts

**Files:**
- Modify: `Sources/MustardKit/Agent/AgentTaskPrompt.swift`
- Modify: `Sources/MustardKit/Agent/AgentTaskCoordinator.swift`
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `Tests/MustardTests/AgentTaskPromptTests.swift`
- Modify: `Tests/MustardTests/AgentTaskCoordinatorTests.swift`

- [ ] **Step 1: Write the failing prompt-selection test**

```swift
func test_promptRendersOnlySelectedApprovedMemories() throws {
    let prompt = AgentTaskPrompt.firstTurn(task: task, run: run,
        contract: "contract",
        approvedInstructions: ["Use Given/When/Then", "Keep titles concise"])
    XCTAssertTrue(prompt.contains("## Approved learning"))
    XCTAssertTrue(prompt.contains("- Use Given/When/Then"))
    XCTAssertTrue(prompt.contains("- Keep titles concise"))
}
```

Also assert the heading is omitted for an empty memory array and that raw evidence or
historical transcripts are not included.

- [ ] **Step 2: Run and verify the prompt lacks learning**

```bash
swift test --filter AgentTaskPromptTests
```

Expected: the learning assertions fail.

- [ ] **Step 3: Add compact memory rendering**

Render `approvedInstructions` as at most 12 markdown bullets under
`## Approved learning`. Do not
render scope metadata, evidence IDs, or proposal history into the agent prompt.

- [ ] **Step 4: Inject the learning service into the coordinator**

Extend the coordinator initializer with `learning: AgentLearningService? = nil`. Before
building each prompt call
`learning?.selectedMemories(for: run).map(\.instruction) ?? []`. In
`MustardApp.init`, create one `AgentLearningService` and pass the same instance to the
coordinator; inject it into the view environment.

- [ ] **Step 5: Record review actions through the coordinator**

Extend:

```swift
requestChanges(_ task: MustardTask, feedback: String, remember: Bool = false)
accept(_ task: MustardTask, remember: Bool = false)
takeBack(_ task: MustardTask, feedback: String = "")
```

Each method records the appropriate `AgentReviewOutcome` before changing task state.
After each decoded turn, encode `result.learningCandidates ?? []` with `JSONEncoder` and
store the UTF-8 JSON in `run.latestLearningCandidatesJSON`. Review methods decode that
field and use the first candidate matching the run's task type/skill/project; if none is
present, record evidence without producing a proposal. Never infer a reusable instruction
from acceptance alone.

- [ ] **Step 6: Run coordinator/prompt tests and commit**

```bash
swift test --filter 'AgentTaskPromptTests|AgentTaskCoordinatorTests|AgentLearningServiceTests'
git add Sources/MustardKit/Agent/AgentTaskPrompt.swift Sources/MustardKit/Agent/AgentTaskCoordinator.swift Sources/Mustard/MustardApp.swift Tests/MustardTests/AgentTaskPromptTests.swift Tests/MustardTests/AgentTaskCoordinatorTests.swift
git commit -m "feat(agent): apply approved learning to task prompts" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 6: Add the learning proposal and memory management UI

**Files:**
- Create: `Sources/MustardKit/Views/AgentLearningQueueView.swift`
- Modify: `Sources/MustardKit/Views/AgentConsoleView.swift`
- Modify: `Sources/MustardKit/Views/AgentConversationView.swift`
- Modify: `Sources/MustardKit/Views/SettingsView.swift`
- Modify: `Sources/MustardKit/PreviewData.swift`

- [ ] **Step 1: Build the proposal queue**

`AgentLearningQueueView` queries pending proposals and shows instruction, scope, evidence
count, confidence, and destination. Provide local editable instruction/scope fields and
buttons wired to `AgentLearningService.approve`/`reject`. A skill proposal additionally
shows its target path and monospace `diffPreview`.

- [ ] **Step 2: Add “Remember this” to review feedback**

In `AgentConversationView`, add a checkbox beside Request Changes:

```swift
Toggle("Remember this for similar tasks", isOn: $rememberFeedback)
```

Pass the value to the coordinator. Hide it when feedback is empty; acceptance without
feedback does not show the toggle.

- [ ] **Step 3: Mount proposals in Agent Console**

Place **Learning proposals** below Needs You/Needs Review and above source
recommendations. Show its pending count in the section label but do not add it to the
urgent waiting badge; learning proposals are improvements, not blockers.

- [ ] **Step 4: Add approved-memory management to Settings**

List memories grouped by scope with enable toggle, inline instruction edit, and delete.
Display evidence count and version. Mutations call `AgentLearningService`; views never
write SwiftData fields directly except through `@Bindable` text staged before Save.

- [ ] **Step 5: Add preview fixtures and build**

Add one pending project-memory proposal, one pending skill diff, one enabled task-type
memory, and one disabled global memory to `PreviewData`.

```bash
swift build
./build-app.sh
open build/Mustard.app
```

Ask Leon to confirm proposal readability, scope editing, diff display, and memory controls.

- [ ] **Step 6: Commit learning surfaces**

```bash
git add Sources/MustardKit/Views/AgentLearningQueueView.swift Sources/MustardKit/Views/AgentConsoleView.swift Sources/MustardKit/Views/AgentConversationView.swift Sources/MustardKit/Views/SettingsView.swift Sources/MustardKit/PreviewData.swift
git commit -m "feat(agent): add approved learning controls" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 7: Apply approved skill changes with snapshot and undo

**Files:**
- Create: `Sources/MustardKit/Logic/SkillChangePlan.swift`
- Create: `Sources/MustardKit/Agent/SkillChangeIO.swift`
- Create: `Tests/MustardTests/SkillChangePlanTests.swift`
- Create: `Tests/MustardTests/FileSkillChangeIOTests.swift`
- Modify: `Sources/MustardKit/Agent/AgentLearningService.swift`
- Modify: `Sources/MustardKit/Views/AgentLearningQueueView.swift`

- [ ] **Step 1: Write failing path-safety and operation-plan tests**

```swift
func test_validSkillChange_requiresSkillFileInsideAllowedRoot() {
    XCTAssertNotNil(SkillChangePlan.make(target: "/kb/DL/.claude/skills/release/SKILL.md",
        allowedRoots: ["/kb/DL"], proposalUID: "p1"))
    XCTAssertNil(SkillChangePlan.make(target: "/tmp/other/SKILL.md",
        allowedRoots: ["/kb/DL"], proposalUID: "p1"))
    XCTAssertNil(SkillChangePlan.make(target: "/kb/DL/notes/readme.md",
        allowedRoots: ["/kb/DL"], proposalUID: "p1"))
}

func test_planUsesApplicationSupportBackup_notRepository() throws {
    let plan = try XCTUnwrap(SkillChangePlan.make(
        target: "/kb/DL/.claude/skills/release/SKILL.md",
        allowedRoots: ["/kb/DL"], proposalUID: "p1",
        backupRoot: "/app/Mustard/SkillBackups"))
    XCTAssertEqual(plan.backupPath, "/app/Mustard/SkillBackups/p1/SKILL.md")
}
```

- [ ] **Step 2: Write failing file IO tests in a temporary directory**

Verify `apply` copies original text to backup before atomically replacing the target,
and `undo` restores the backup exactly. Verify a missing target or existing backup fails
without truncating anything.

- [ ] **Step 3: Implement the pure plan and injected IO**

```swift
public struct SkillChangeOperation: Equatable {
    public let targetPath: String
    public let backupPath: String
}

public protocol SkillChangeIO {
    func apply(_ operation: SkillChangeOperation, replacement: String) throws
    func undo(_ operation: SkillChangeOperation) throws
}
```

Canonicalize paths with `URL.standardizedFileURL`, require target basename `SKILL.md`,
and require it to be a descendant of one configured source working directory. Use
`Data.write(options: .atomic)` for replacement. Store backups under
`~/Library/Application Support/Mustard/SkillBackups/<proposalUID>/SKILL.md`.

- [ ] **Step 4: Route skill approval through the safety boundary**

Extend `AgentLearningService` with an injected `SkillChangeIO` and this initializer:

```swift
public convenience init(context: ModelContext) {
    self.init(context: context, skillIO: FileSkillChangeIO())
}
public init(context: ModelContext, skillIO: any SkillChangeIO)
```

Change approval to `approve(_ proposal: LearningProposal, allowedRoots: [String] = [],
now: Date = .now)`. For `.skillChange`, it requires non-empty target,
replacement, and diff preview, builds a safe operation from current source settings,
calls `skillIO.apply`, then marks the proposal approved. Persist `backupPath` on the
proposal. If IO fails, leave it pending and surface the error.

Add `undoSkillChange(_:)` that calls IO undo, marks the proposal pending again, and does
not commit or push the repository.

- [ ] **Step 5: Add Apply and Undo confirmation UI**

The proposal view must show the full target and diff, then require an explicit **Apply
skill change** click. Approved skill proposals show **Undo**. These are local file writes;
there is no Git action.

- [ ] **Step 6: Run tests and commit**

```bash
swift test --filter 'SkillChangePlanTests|FileSkillChangeIOTests|AgentLearningServiceTests'
git add Sources/MustardKit/Logic/SkillChangePlan.swift Sources/MustardKit/Agent/SkillChangeIO.swift Sources/MustardKit/Agent/AgentLearningService.swift Sources/MustardKit/Models/LearningProposal.swift Sources/MustardKit/Views/AgentLearningQueueView.swift Tests/MustardTests/SkillChangePlanTests.swift Tests/MustardTests/FileSkillChangeIOTests.swift Tests/MustardTests/AgentLearningServiceTests.swift
git commit -m "feat(agent): apply reversible skill improvements" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Task 8: Document and verify the complete learning loop

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture.md`
- Modify: `docs/build-order.md`
- Modify: `docs/specs/2026-07-13-agent-task-sessions-design.md`

- [ ] **Step 1: Document the exact learning lifecycle**

```text
review → AgentReviewEvent → eligibility policy → pending LearningProposal
→ Leon approves → AgentMemory or snapshotted skill replacement
→ relevant future AgentTaskPrompt → inspect/edit/disable/delete/undo
```

State the explicit threshold: “Remember this” is immediate; otherwise the same scoped
candidate requires two comparable corrections. State that acceptance alone never creates
a reusable instruction.

- [ ] **Step 2: Mark the learning slice complete only after verification**

Update build order and the design status. Keep Codex runtime, limited parallelism, live
streaming, automatic connected launch, and earned auto-accept listed as fast-follows.

- [ ] **Step 3: Run focused and full verification**

```bash
swift test --filter 'LearningModelTests|LearningPolicyTests|AgentMemorySelectorTests|AgentLearningServiceTests|SkillChangePlanTests|FileSkillChangeIOTests|AgentTaskPromptTests|AgentTaskCoordinatorTests'
swift test
swift build
./build-app.sh
```

Expected: all commands exit 0.

- [ ] **Step 4: Run the manual learning acceptance scenario**

1. revise the same safe test-task pattern twice and confirm one pending proposal
2. edit its instruction/scope, approve it, and verify it appears in Settings
3. start a matching task and confirm the prompt/runtime stub receives the memory
4. start a non-matching project task and confirm the memory is absent
5. disable the memory and confirm it is no longer injected
6. apply a skill change to a temporary test skill, verify snapshot, then undo it

- [ ] **Step 5: Commit documentation**

```bash
git add CLAUDE.md docs/architecture.md docs/build-order.md docs/specs/2026-07-13-agent-task-sessions-design.md
git commit -m "docs(agent): document approved learning loop" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

## Final completion gate

Before claiming the learning loop is complete:

- no proposal applies without Leon's explicit approval
- one implicit correction is insufficient
- scope selection is deterministic and narrowest-first
- disabled/deleted memories do not enter prompts
- prompts contain compact instructions, not raw transcripts/evidence
- skill changes are constrained to allowed `SKILL.md` files, snapshotted, atomic, and undoable
- no skill change is committed or pushed automatically
- all tests/builds pass and Leon confirms the native UI
- all implementation remains on its feature branch; do not merge to `main`, push, or
  create a ready-to-merge PR until Leon has completed thorough hands-on testing and gives
  explicit approval
