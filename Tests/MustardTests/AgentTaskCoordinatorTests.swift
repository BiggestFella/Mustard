import XCTest
import SwiftData
@testable import MustardKit

private actor ScriptedAgentRuntime: AgentRuntime {
    private var responses: [AgentRuntimeResponse]
    private var healthResponses: [AgentRuntimeHealth]
    private var suspendNextInvocation: Bool
    private var suspendCancellation: Bool
    private var controlHealthResponses: Bool
    private var knownSessionIDs: Set<String>
    private var invocationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var healthContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    private(set) var startRequests: [AgentRuntimeRequest] = []
    private(set) var resumeRequests: [AgentRuntimeRequest] = []
    private(set) var cancelCount = 0
    private(set) var healthCount = 0

    init(
        responses: [AgentRuntimeResponse] = [],
        healthResponses: [AgentRuntimeHealth] = [],
        suspendNextInvocation: Bool = false,
        suspendCancellation: Bool = false,
        controlHealthResponses: Bool = false,
        knownSessionIDs: Set<String> = []
    ) {
        self.responses = responses
        self.healthResponses = healthResponses
        self.suspendNextInvocation = suspendNextInvocation
        self.suspendCancellation = suspendCancellation
        self.controlHealthResponses = controlHealthResponses
        self.knownSessionIDs = knownSessionIDs
    }

    func start(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        startRequests.append(request)
        knownSessionIDs.insert(request.sessionID)
        await suspendIfRequested()
        return popResponse()
    }

    func resume(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        resumeRequests.append(request)
        guard knownSessionIDs.contains(request.sessionID) else {
            return .failure(.sessionMissing("Scripted runtime has never started session \(request.sessionID)"))
        }
        await suspendIfRequested()
        return popResponse()
    }

    func cancel() async {
        cancelCount += 1
        guard suspendCancellation else { return }
        suspendCancellation = false
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
    }

    func health() async -> AgentRuntimeHealth {
        let index = healthCount
        healthCount += 1
        let response = healthResponses.isEmpty ? .available : healthResponses.removeFirst()
        if controlHealthResponses {
            await withCheckedContinuation { continuation in
                healthContinuations[index] = continuation
            }
        }
        return response
    }

    func releaseInvocation() {
        invocationContinuation?.resume()
        invocationContinuation = nil
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func releaseHealth(_ index: Int) {
        healthContinuations.removeValue(forKey: index)?.resume()
    }

    var invocationCount: Int { startRequests.count + resumeRequests.count }

    private func suspendIfRequested() async {
        guard suspendNextInvocation else { return }
        suspendNextInvocation = false
        await withCheckedContinuation { continuation in
            invocationContinuation = continuation
        }
    }

    private func popResponse() -> AgentRuntimeResponse {
        guard !responses.isEmpty else {
            return .failure(.process("No scripted response"))
        }
        return responses.removeFirst()
    }
}

private extension AgentRuntimeResponse {
    static func completed(
        _ summary: String,
        artifacts: [AgentArtifact] = []
    ) -> Self {
        .success(.init(
            outcome: .completed,
            message: summary,
            questions: [],
            summary: summary,
            artifacts: artifacts,
            retryDisposition: .none,
            errorCategory: nil,
            connectedCapability: nil
        ))
    }

    static func question(_ text: String) -> Self {
        .success(.init(
            outcome: .needsInput,
            message: text,
            questions: [text],
            summary: "",
            artifacts: [],
            retryDisposition: .none,
            errorCategory: nil,
            connectedCapability: nil
        ))
    }

    static func connected(_ capability: String) -> Self {
        .success(.init(
            outcome: .requiresConnectedWorker,
            message: "A connected worker is required for \(capability).",
            questions: [],
            summary: "Waiting for a connected worker",
            artifacts: [],
            retryDisposition: .none,
            errorCategory: nil,
            connectedCapability: capability
        ))
    }

    static func cancelled(_ message: String = "Cancelled") -> Self {
        .success(.init(
            outcome: .cancelled,
            message: message,
            questions: [],
            summary: message,
            artifacts: [],
            retryDisposition: .none,
            errorCategory: nil,
            connectedCapability: nil
        ))
    }
}

private final class SequencedTestClock {
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        precondition(!values.isEmpty, "Test clock exhausted")
        return values.removeFirst()
    }
}

@MainActor
final class AgentTaskCoordinatorTests: XCTestCase {
    private let firstTurn = ISO8601DateFormatter().date(from: "2026-07-13T01:00:00Z")!
    private let secondTurn = ISO8601DateFormatter().date(from: "2026-07-13T02:00:00Z")!
    private let thirdTurn = ISO8601DateFormatter().date(from: "2026-07-13T03:00:00Z")!

    func test_runNextCompletesSimpleTaskIntoReviewWithArtifactLinks() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .completed("Release ticket created", artifacts: [
                AgentArtifact(label: "Shortcut", url: "https://app.shortcut.com/story/42"),
            ]),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Create release ticket", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.project, "DL-Knowledge-Base")
        XCTAssertEqual(run.workingDirectory, "/kb/DL")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(run.providerSessionID)))
        XCTAssertEqual(run.attemptCount, 1)
        XCTAssertEqual(run.startedAt, firstTurn)
        XCTAssertEqual(run.completedAt, secondTurn)
        XCTAssertEqual(run.lastOutcomeRaw, AgentTurnOutcome.completed.rawValue)
        XCTAssertNil(run.lastError)
        XCTAssertEqual(run.orderedMessages.map(\.kind), [.progress, .result])
        XCTAssertEqual(run.orderedMessages.last?.links, [
            TaskLink(label: "Shortcut", url: "https://app.shortcut.com/story/42"),
        ])
        XCTAssertEqual(task.links, run.orderedMessages.last?.links)
        let startCount = await runtime.startRequests.count
        let resumeCount = await runtime.resumeRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.activeTitle)
    }

    func test_runNext_areaLessTask_routesViaDefault_notStranded() async throws {
        // F26: a voice hand-off with no client area would strand (route() → nil)
        // without the default. With a default route injected, it's picked up and run.
        let runtime = ScriptedAgentRuntime(responses: [.completed("Drafted", artifacts: [])])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self,
            configurations: configuration)
        let context = ModelContext(container)
        let coordinator = AgentTaskCoordinator(
            context: context, runtime: runtime,
            persist: { try context.save() },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn },
            defaultRouteProvider: { AgentTaskRoute(project: "Code Heroes", workingDirectory: "/kb/ch-work") })

        let task = MustardTask(title: "Email Bree", owner: .agent)   // NO list/area
        task.stage = .queued
        task.actionType = .draftEmail
        context.insert(task)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertNotEqual(task.stage, .queued, "should not strand — the default route unblocks it")
        XCTAssertEqual(task.agentRun?.workingDirectory, "/kb/ch-work")
        XCTAssertEqual(task.agentRun?.project, "Code Heroes")
        XCTAssertNil(coordinator.lastError)
    }

    func test_runNext_areaLessTask_strandsWhenNoDefaultRouteConfigured() async throws {
        // No meeting vault set → provider returns nil → area-less task stays put and the
        // coordinator reports it, rather than routing nowhere.
        let runtime = ScriptedAgentRuntime(responses: [.completed("x", artifacts: [])])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self,
            configurations: configuration)
        let context = ModelContext(container)
        let coordinator = AgentTaskCoordinator(
            context: context, runtime: runtime,
            persist: { try context.save() },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn },
            defaultRouteProvider: { nil })

        let task = MustardTask(title: "Email Bree", owner: .agent)
        task.stage = .queued
        task.actionType = .draftEmail
        context.insert(task)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertNil(task.agentRun)
        XCTAssertNotNil(coordinator.lastError)
    }

    func test_completedTurnMaterializesValidDraftsAndDropsUnsafeOnes() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .success(.init(outcome: .completed, message: "done", questions: [], summary: "Drafted",
                           artifacts: [], retryDisposition: .none, errorCategory: nil,
                           connectedCapability: nil, drafts: [
                               .init(kind: "comment", title: "Jira reply", path: "_agent/drafts/u1/reply.md"),
                               .init(kind: "email", title: "Escape attempt", path: "../../etc/passwd"),
                           ])),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Draft it", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        let drafts = task.agentRun?.drafts ?? []
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.kind, .comment)
        XCTAssertEqual(drafts.first?.relativePath, "_agent/drafts/u1/reply.md")
    }

    func test_secondTurnReturningSameDraftPathUpdatesInPlaceWithoutDuplicating() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .success(.init(outcome: .completed, message: "done", questions: [], summary: "Drafted",
                           artifacts: [], retryDisposition: .none, errorCategory: nil,
                           connectedCapability: nil, drafts: [
                               .init(kind: "comment", title: "Jira reply", path: "_agent/drafts/u1/reply.md"),
                           ])),
            .success(.init(outcome: .completed, message: "revised", questions: [], summary: "Revised",
                           artifacts: [], retryDisposition: .none, errorCategory: nil,
                           connectedCapability: nil, drafts: [
                               .init(kind: "comment", title: "Jira reply (v2)", path: "_agent/drafts/u1/reply.md"),
                           ])),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Draft it", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)
        coordinator.requestChanges(task, feedback: "Tighten it", now: secondTurn)
        await coordinator.runNext(settings: settings, now: secondTurn)

        let drafts = task.agentRun?.drafts ?? []
        XCTAssertEqual(drafts.count, 1, "a re-returned draft path must not duplicate the card")
        XCTAssertEqual(drafts.first?.title, "Jira reply (v2)")
    }

    func test_outcomeSaveFailureRollsBackMaterializedDrafts() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .success(.init(outcome: .completed, message: "done", questions: [], summary: "Drafted",
                           artifacts: [], retryDisposition: .none, errorCategory: nil,
                           connectedCapability: nil, drafts: [
                               .init(kind: "comment", title: "Jira reply", path: "_agent/drafts/u1/reply.md"),
                           ])),
        ])
        let container = try makeContainer()
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                saveCount += 1
                // Save 1 is the pre-flight; save 2 is the outcome save — fail it.
                if saveCount == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Draft rollback", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentDraft>()).count, 0,
                       "drafts materialized in the failed outcome save must be rolled back")
        XCTAssertTrue(task.agentRun?.drafts?.isEmpty ?? true)
    }

    func test_needsInputReleasesSlotAndSecondRunNextRunsNextTask() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .question("Which version?"),
            .completed("Other done"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let first = insertRoutedTask(in: context, title: "Prep release", stage: .forAgent, created: 1)
        let second = insertRoutedTask(in: context, title: "Other", stage: .forAgent, created: 2)

        await coordinator.runNext(settings: settings, now: firstTurn)
        XCTAssertEqual(first.stage, .needsInput)
        XCTAssertEqual(first.agentRun?.state, .needsInput)
        XCTAssertEqual(first.agentRun?.orderedMessages.last?.kind, .question)
        XCTAssertFalse(coordinator.isRunning)

        await coordinator.runNext(settings: settings, now: secondTurn)
        XCTAssertEqual(second.stage, .needsReview)
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 2)
    }

    func test_replyRequeuesAndResumeUsesSameSessionAndLatestAnswer() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .question("Which version?"),
            .completed("Prepared"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Prep release", stage: .forAgent)
        await coordinator.runNext(settings: settings, now: firstTurn)
        let session = try XCTUnwrap(task.agentRun?.providerSessionID)

        coordinator.reply(to: task, text: "  2.21.0  ", now: secondTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.agentRun?.state, .queued)
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.kind, .answer)
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.content, "2.21.0")
        XCTAssertEqual(task.agentRun?.providerSessionID, session)

        await coordinator.runNext(settings: settings, now: secondTurn)

        let requests = await runtime.resumeRequests
        XCTAssertEqual(requests.map(\.sessionID), [session])
        XCTAssertTrue(try XCTUnwrap(requests.first).prompt.contains("2.21.0"))
        XCTAssertTrue(try XCTUnwrap(requests.first).prompt.contains("Never send email"))
        XCTAssertFalse(try XCTUnwrap(requests.first).prompt.contains("# Mustard delegated-task worker contract"))
        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(task.agentRun?.resumeCount, 1)
    }

    func test_redelegationResumeUsesFreshEditedDelegationMessage() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Updated release prepared")],
            knownSessionIDs: ["existing-session"]
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Old request", stage: .planned)
        task.owner = .me
        let run = AgentRun(task: task)
        run.providerSessionID = "existing-session"
        run.state = .completed
        task.agentRun = run
        let oldMessage = AgentMessage(
            run: run,
            sequence: 0,
            role: .human,
            kind: .delegation,
            content: "Old request"
        )
        context.insert(run)
        context.insert(oldMessage)
        try context.save()
        task.title = "Updated release request"
        task.notes = "Use the edited migration checklist."
        let service = AgentService(context: context, persist: { try context.save() })

        service.delegate(task)
        await coordinator.runNext(settings: settings, now: firstTurn)

        let resumes = await runtime.resumeRequests
        XCTAssertEqual(resumes.count, 1)
        XCTAssertTrue(resumes[0].prompt.contains(
            "Updated release request\n\nUse the edited migration checklist."
        ))
    }

    func test_requestChangesRequeuesAndResumeUsesLatestReviewFeedback() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .completed("Draft one"),
            .completed("Draft two"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Write draft", stage: .forAgent)
        await coordinator.runNext(settings: settings, now: firstTurn)
        let session = try XCTUnwrap(task.agentRun?.providerSessionID)

        coordinator.requestChanges(task, feedback: "  Add the migration caveat. ", now: secondTurn)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.kind, .reviewFeedback)
        XCTAssertFalse(task.agentRun?.requiresConnectedWorker ?? true)

        await coordinator.runNext(settings: settings, now: secondTurn)

        let resumeRequests = await runtime.resumeRequests
        let request = try XCTUnwrap(resumeRequests.first)
        XCTAssertEqual(request.sessionID, session)
        XCTAssertTrue(request.prompt.contains("Add the migration caveat."))
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_replyRejectsWhitespaceWithoutChangingWaitingTask() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.question("Which version?")])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Prep release", stage: .forAgent)
        await coordinator.runNext(settings: settings, now: firstTurn)
        let messageCount = try XCTUnwrap(task.agentRun).orderedMessages.count

        coordinator.reply(to: task, text: "  \n\t ", now: secondTurn)

        XCTAssertEqual(task.stage, .needsInput)
        XCTAssertEqual(task.agentRun?.state, .needsInput)
        XCTAssertEqual(task.agentRun?.orderedMessages.count, messageCount)
        XCTAssertEqual(coordinator.lastError, "A reply cannot be empty.")
    }

    func test_requestChangesRequiresExistingRun() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "No run", stage: .needsReview)

        coordinator.requestChanges(task, feedback: "Revise it", now: secondTurn)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertNil(task.agentRun)
        XCTAssertEqual(coordinator.lastError, "This task has no agent run to resume.")
    }

    func test_missingRouteLeavesTaskAndExistingRunUnchangedAndReportsError() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Should not run")])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = MustardTask(title: "Unrouted", owner: .agent)
        task.stage = .queued
        let run = AgentRun(task: task, workingDirectory: "/old", project: "Old")
        run.state = .failed
        task.agentRun = run
        context.insert(task)
        context.insert(run)
        try context.save()

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.project, "Old")
        XCTAssertEqual(run.workingDirectory, "/old")
        XCTAssertTrue(coordinator.lastError?.contains("route") == true)
        XCTAssertFalse(coordinator.isRunning)
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func test_malformedOutputRecordsErrorAndRequeuesForLaterPolicy() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .failure(.malformedOutput("not-json")),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Malformed", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.completedAt, secondTurn)
        XCTAssertEqual(run.orderedMessages.last?.kind, .error)
        XCTAssertTrue(run.lastError?.contains("Malformed") == true)
        XCTAssertEqual(coordinator.lastError, run.lastError)
    }

    func test_connectedFallbackIsQueuedFlaggedAndSkippedOnNextSelection() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .connected("gmail"),
            .completed("Ordinary task done"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let connected = insertRoutedTask(in: context, title: "Email draft", stage: .forAgent, created: 1)
        let ordinary = insertRoutedTask(in: context, title: "Local notes", stage: .forAgent, created: 2)

        await coordinator.runNext(settings: settings, now: firstTurn)
        XCTAssertEqual(connected.stage, .queued)
        XCTAssertEqual(connected.agentRun?.state, .queued)
        XCTAssertTrue(connected.agentRun?.requiresConnectedWorker == true)
        XCTAssertEqual(connected.agentRun?.orderedMessages.last?.kind, .recovery)

        await coordinator.runNext(settings: settings, now: secondTurn)
        XCTAssertEqual(ordinary.stage, .needsReview)
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 2)
    }

    func test_overlappingRunNextDoesNothingWhileFirstCallIsActive() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("First done"), .completed("Second done")],
            suspendNextInvocation: true
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let first = insertRoutedTask(in: context, title: "First", stage: .forAgent, created: 1)
        let second = insertRoutedTask(in: context, title: "Second", stage: .forAgent, created: 2)

        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        XCTAssertTrue(coordinator.isRunning)

        await coordinator.runNext(settings: settings, now: secondTurn)
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(second.stage, .forAgent)

        await runtime.releaseInvocation()
        await active.value
        XCTAssertEqual(first.stage, .needsReview)
    }

    func test_sessionMissingAllocatesReplacementAndPerformsExactlyOneRecoveryStart() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [
                .failure(.sessionMissing("No conversation found")),
                .completed("Recovered"),
            ],
            knownSessionIDs: ["11111111-1111-1111-1111-111111111111"]
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Resume me", stage: .queued)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.providerSessionID = "11111111-1111-1111-1111-111111111111"
        let answer = AgentMessage(run: run, sequence: 4, role: .human, kind: .answer, content: "Latest answer")
        answer.createdAt = firstTurn
        task.agentRun = run
        context.insert(run)
        context.insert(answer)
        try context.save()

        await coordinator.runNext(settings: settings, now: secondTurn)

        let resumes = await runtime.resumeRequests
        let starts = await runtime.startRequests
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(resumes.first?.sessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertNotEqual(starts.first?.sessionID, resumes.first?.sessionID)
        XCTAssertEqual(run.providerSessionID, starts.first?.sessionID)
        XCTAssertTrue(try XCTUnwrap(starts.first).prompt.contains("Latest answer"))
        XCTAssertEqual(run.orderedMessages.filter { $0.kind == .recovery }.count, 1)
        XCTAssertEqual(run.attemptCount, 2)
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_repeatedSessionMissingDoesNotLoopAndBecomesNormalFailure() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [
                .failure(.sessionMissing("Session missing")),
                .failure(.sessionMissing("Replacement also missing")),
                .completed("Must never be consumed"),
            ],
            knownSessionIDs: ["22222222-2222-2222-2222-222222222222"]
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Broken session", stage: .queued)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.providerSessionID = "22222222-2222-2222-2222-222222222222"
        task.agentRun = run
        context.insert(run)
        try context.save()

        await coordinator.runNext(settings: settings, now: firstTurn)

        let resumeCount = await runtime.resumeRequests.count
        let startCount = await runtime.startRequests.count
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.orderedMessages.last?.kind, .error)
        XCTAssertTrue(run.lastError?.contains("Replacement also missing") == true)
    }

    func test_authenticationFailurePausesGloballyPreservesSessionAndRetryHealthControlsPause() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.failure(.authenticationRequired("Please log in"))],
            healthResponses: [.unavailable("CLI unavailable"), .available]
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let first = insertRoutedTask(in: context, title: "Auth blocked", stage: .forAgent, created: 1)
        _ = insertRoutedTask(in: context, title: "Do not consume", stage: .forAgent, created: 2)

        await coordinator.runNext(settings: settings, now: firstTurn)
        let session = try XCTUnwrap(first.agentRun?.providerSessionID)

        XCTAssertTrue(coordinator.authenticationRequired)
        XCTAssertEqual(first.stage, .queued)
        XCTAssertEqual(first.agentRun?.state, .queued)
        XCTAssertEqual(first.agentRun?.providerSessionID, session)
        XCTAssertNil(first.agentRun?.completedAt)

        await coordinator.runNext(settings: settings, now: secondTurn)
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 1)

        await coordinator.retryAuthentication()
        XCTAssertTrue(coordinator.authenticationRequired)
        XCTAssertEqual(coordinator.lastError, "CLI unavailable")

        await coordinator.retryAuthentication()
        XCTAssertFalse(coordinator.authenticationRequired)
        XCTAssertNil(coordinator.lastError)
        let healthCount = await runtime.healthCount
        XCTAssertEqual(healthCount, 2)
    }

    func test_takeBackDuringActiveCallPreservesLocalStateAfterLateSuccess() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Late success")],
            suspendNextInvocation: true
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Take it back", stage: .forAgent)

        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        coordinator.takeBack(task, now: secondTurn)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun?.state, .cancelled)
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.createdAt, secondTurn)
        await waitForCancel(runtime)

        await runtime.releaseInvocation()
        await active.value
        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun?.state, .cancelled)
        XCTAssertFalse(task.agentRun?.orderedMessages.contains { $0.content == "Late success" } ?? true)
    }

    func test_takeBackSupportsAgentOwnedProposedAndApprovalStages() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let proposed = insertRoutedTask(in: context, title: "Proposed", stage: .inbox)
        let approval = insertRoutedTask(in: context, title: "Approval", stage: .needsApproval)

        coordinator.takeBack(proposed, now: firstTurn)
        coordinator.takeBack(approval, now: firstTurn)

        XCTAssertEqual(proposed.owner, .me)
        XCTAssertEqual(proposed.stage, .planned)
        XCTAssertEqual(approval.owner, .me)
        XCTAssertEqual(approval.stage, .planned)
    }

    func test_cancelActiveImmediatelyCancelsLocalStateAndLateResponseCannotOverwriteIt() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.cancelled("Late provider acknowledgement")],
            suspendNextInvocation: true
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Cancel", stage: .forAgent)

        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        coordinator.cancelActive()

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun?.state, .cancelled)
        await waitForCancel(runtime)

        await runtime.releaseInvocation()
        await active.value
        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun?.state, .cancelled)
    }

    func test_pendingCancellationIsDrainedBeforeCoordinatorCanStartLaterTurn() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Late old result"), .completed("Next done")],
            suspendNextInvocation: true,
            suspendCancellation: true
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let cancelled = insertRoutedTask(in: context, title: "Cancel old", stage: .forAgent, created: 1)
        let next = insertRoutedTask(in: context, title: "Run next", stage: .forAgent, created: 2)

        let oldTurn = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        coordinator.takeBack(cancelled, now: secondTurn)
        await waitForCancel(runtime)
        await runtime.releaseInvocation()
        await Task.yield()

        XCTAssertTrue(coordinator.isRunning, "The old turn must retain the serial slot until cancellation drains")
        await coordinator.runNext(settings: settings, now: secondTurn)
        let countWhileCancelling = await runtime.invocationCount
        XCTAssertEqual(countWhileCancelling, 1)
        XCTAssertEqual(next.stage, .forAgent)

        await runtime.releaseCancellation()
        await oldTurn.value
        await coordinator.runNext(settings: settings, now: secondTurn)

        let finalInvocationCount = await runtime.invocationCount
        XCTAssertEqual(finalInvocationCount, 2)
        XCTAssertEqual(next.stage, .needsReview)
    }

    func test_outcomeSaveFailureRollsBackAppliedCompletionAndMessage() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Must not appear applied")],
            suspendNextInvocation: true
        )
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(context: context, runtime: runtime, persist: {
            saveCount += 1
            if saveCount == 2 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, nowProvider: { self.secondTurn })
        let task = insertRoutedTask(in: context, title: "Persistence fails", stage: .forAgent)
        let unrelated = MustardTask(title: "Unrelated edit")
        unrelated.notes = "Saved value"
        context.insert(unrelated)

        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        unrelated.notes = "Unsaved edit made during agent work"
        await runtime.releaseInvocation()
        await active.value

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.completedAt, secondTurn)
        XCTAssertFalse(run.orderedMessages.contains { $0.kind == .result })
        XCTAssertEqual(unrelated.notes, "Unsaved edit made during agent work")
        XCTAssertTrue(coordinator.lastError?.contains("Could not save the agent turn result") == true)
        XCTAssertFalse(coordinator.isRunning)

        let fresh = ModelContext(container)
        let durableUnrelated = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<MustardTask>()).first { $0.uid == unrelated.uid }
        )
        XCTAssertEqual(durableUnrelated.notes, "Unsaved edit made during agent work")
    }

    func test_runtimeCancelledOutcomeUsesCancellationDecisionWhenNoLocalCancellationOccurred() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.cancelled()])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Provider cancelled", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun?.state, .cancelled)
        XCTAssertEqual(task.agentRun?.lastOutcomeRaw, AgentTurnOutcome.cancelled.rawValue)
    }

    func test_runtimeCancelledFailureSaveFailureCompensatesDurablyAndPreservesUnrelatedEdit() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.failure(.cancelled("Provider stopped"))],
            suspendNextInvocation: true
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                saveCount += 1
                if saveCount == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Runtime cancellation failure", stage: .forAgent)
        let unrelated = MustardTask(title: "Unrelated")
        unrelated.notes = "saved"
        context.insert(unrelated)

        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        unrelated.notes = "dirty during runtime"
        await runtime.releaseInvocation()
        await active.value

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        XCTAssertNil(run.lastOutcomeRaw)
        XCTAssertEqual(run.completedAt, secondTurn)
        XCTAssertEqual(run.orderedMessages.map(\.kind), [.progress, .error])
        XCTAssertTrue(run.lastError?.contains("Could not save the agent turn result") == true)
        XCTAssertEqual(run.orderedMessages.last?.content, run.lastError)
        XCTAssertEqual(unrelated.notes, "dirty during runtime")
        XCTAssertEqual(saveCount, 3)

        let fresh = ModelContext(container)
        let durableTask = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<MustardTask>()).first { $0.uid == task.uid }
        )
        XCTAssertEqual(durableTask.owner, .agent)
        XCTAssertEqual(durableTask.stage, .queued)
        XCTAssertEqual(durableTask.agentRun?.state, .failed)
        XCTAssertNil(durableTask.agentRun?.lastOutcomeRaw)
        XCTAssertEqual(durableTask.agentRun?.completedAt, secondTurn)
        XCTAssertEqual(durableTask.agentRun?.orderedMessages.map(\.kind), [.progress, .error])
        XCTAssertEqual(
            durableTask.agentRun?.orderedMessages.last?.content,
            durableTask.agentRun?.lastError
        )
        XCTAssertTrue(
            durableTask.agentRun?.lastError?.contains("Could not save the agent turn result") == true
        )
        let durableUnrelated = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<MustardTask>()).first { $0.uid == unrelated.uid }
        )
        XCTAssertEqual(durableUnrelated.notes, "dirty during runtime")
    }

    func test_acceptUsesSharedCompletionLogicIncludingRecurrence() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Daily review", stage: .needsReview)
        task.recurrence = .daily
        task.dueAt = firstTurn

        coordinator.accept(task, now: secondTurn)

        let tasks = try context.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(task.stage, .done)
        XCTAssertEqual(task.completedAt, secondTurn)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first { $0.uid != task.uid }?.recurredFrom, task.uid)
    }

    func test_reconcileInterruptedRunsMarksRunAndReturnsOnlyActiveAgentTaskToQueue() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Interrupted", stage: .inProgress)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.state = .running
        task.agentRun = run
        context.insert(run)
        try context.save()

        coordinator.reconcileInterruptedRuns(now: secondTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .interrupted)
        XCTAssertEqual(run.orderedMessages.last?.kind, .recovery)
        XCTAssertEqual(run.orderedMessages.last?.createdAt, secondTurn)
        XCTAssertEqual(run.lastActivityAt, secondTurn)
    }

    func test_reconcileInterruptedRunsReturnsTrueOnSuccess() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Interrupted", stage: .inProgress)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.state = .running
        task.agentRun = run
        context.insert(run)
        try context.save()

        XCTAssertTrue(coordinator.reconcileInterruptedRuns(now: secondTurn))
    }

    func test_reconcileInterruptedRunsSaveFailureRestoresStateThenRetryRecoversWithoutDuplicate() throws {
        let runtime = ScriptedAgentRuntime()
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = true
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Interrupted", stage: .inProgress)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.state = .running
        run.lastActivityAt = thirdTurn
        task.agentRun = run
        context.insert(run)
        let unrelated = MustardTask(title: "Unrelated")
        unrelated.notes = "saved"
        context.insert(unrelated)
        try context.save()
        unrelated.notes = "dirty"

        // First attempt: the save fails, so the touched task/run are restored, no
        // recovery message survives, the unrelated dirty edit is preserved, and the
        // call reports failure so the scheduler will retry.
        XCTAssertFalse(coordinator.reconcileInterruptedRuns(now: secondTurn))
        XCTAssertEqual(task.stage, .inProgress)
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(run.lastActivityAt, thirdTurn)
        XCTAssertTrue(run.orderedMessages.isEmpty)
        XCTAssertEqual(unrelated.notes, "dirty")

        // Retry: the save succeeds, producing exactly one recovery message.
        XCTAssertTrue(coordinator.reconcileInterruptedRuns(now: secondTurn))
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .interrupted)
        XCTAssertEqual(run.orderedMessages.count, 1)
        XCTAssertEqual(run.orderedMessages.last?.kind, .recovery)
        XCTAssertEqual(unrelated.notes, "dirty")
    }

    func test_safeLocalFailureRequeuesWithBackoffAndIsSkippedUntilItsAttemptTime() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.failure(.process("temporary"))])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Local retry", stage: .forAgent)
        task.actionType = .vaultNote

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertEqual(task.agentRun?.autoRetryCount, 1)
        XCTAssertEqual(task.agentRun?.nextAttemptAt, secondTurn.addingTimeInterval(60))
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.kind, .error)

        // A second tick at the same instant must not pick the backing-off task up again.
        await coordinator.runNext(settings: settings, now: secondTurn)
        let startCount = await runtime.startRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(task.stage, .queued)
    }

    func test_externalActionTimeoutGoesToNeedsReviewAsCompletionUncertain() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.failure(.timedOut("slow"))])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Create ticket", stage: .forAgent)
        task.actionType = .ticket

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertNil(task.agentRun?.nextAttemptAt)
        XCTAssertEqual(task.agentRun?.autoRetryCount, 0)
        XCTAssertTrue(task.agentRun?.orderedMessages.last?.content.contains("Completion uncertain") ?? false)
    }

    func test_backingOffTaskYieldsToAnotherRoutableTask() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .failure(.process("temporary")),
            .completed("Other done"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let first = insertRoutedTask(in: context, title: "Backs off", stage: .forAgent, created: 1)
        first.actionType = .vaultNote
        let second = insertRoutedTask(in: context, title: "Routable", stage: .forAgent, created: 2)
        second.actionType = .vaultNote

        await coordinator.runNext(settings: settings, now: firstTurn)
        XCTAssertEqual(first.stage, .queued)          // scheduled for a later attempt
        await coordinator.runNext(settings: settings, now: secondTurn)

        XCTAssertEqual(second.stage, .needsReview)    // not starved by the backing-off task
        XCTAssertEqual(first.stage, .queued)
    }

    func test_automaticRetriesExhaustedFailsToReview() async throws {
        let sessionID = "77777777-7777-7777-7777-777777777777"
        let runtime = ScriptedAgentRuntime(
            responses: [.failure(.process("still broken"))],
            knownSessionIDs: [sessionID]
        )
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Exhausted", stage: .queued)
        task.actionType = .vaultNote
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.providerSessionID = sessionID
        run.autoRetryCount = 3
        task.agentRun = run
        context.insert(run)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertNil(task.agentRun?.nextAttemptAt)
        XCTAssertTrue(task.agentRun?.orderedMessages.last?.content.contains("retries exhausted") ?? false)
    }

    func test_reconcileExternalCreationGoesToUncertainReview() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Ticket in flight", stage: .inProgress)
        task.actionType = .ticket
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.state = .running
        task.agentRun = run
        context.insert(run)
        try context.save()

        XCTAssertTrue(coordinator.reconcileInterruptedRuns(now: secondTurn))

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(run.state, .interrupted)
        XCTAssertTrue(run.orderedMessages.last?.content.contains("Completion uncertain") ?? false)
    }

    func test_structuredFailedWithoutRetryDispositionGoesToReviewNotAnUncappedLoop() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .success(.init(outcome: .failed, message: "Could not find the spec.", questions: [],
                           summary: "", artifacts: [], retryDisposition: .none,
                           errorCategory: "missing_input", connectedCapability: nil)),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Model failure", stage: .forAgent)
        task.actionType = .vaultNote

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertNil(task.agentRun?.nextAttemptAt)

        // A second tick must NOT re-run it — a model-reported failure at .queued would
        // otherwise loop uncapped every tick.
        await coordinator.runNext(settings: settings, now: secondTurn)
        let startCount = await runtime.startRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_structuredFailedWithBackoffDispositionSchedulesBoundedRetry() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .success(.init(outcome: .failed, message: "Transient.", questions: [],
                           summary: "", artifacts: [], retryDisposition: .backoff,
                           errorCategory: nil, connectedCapability: nil)),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Retryable failure", stage: .forAgent)
        task.actionType = .vaultNote

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertEqual(task.agentRun?.autoRetryCount, 1)
        XCTAssertEqual(task.agentRun?.nextAttemptAt, secondTurn.addingTimeInterval(60))
    }

    func test_takeBackClearsRetryBudget() throws {
        let runtime = ScriptedAgentRuntime()
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Backed off", stage: .queued)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.autoRetryCount = 2
        run.nextAttemptAt = thirdTurn
        task.agentRun = run
        context.insert(run)

        coordinator.takeBack(task, now: secondTurn)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(run.autoRetryCount, 0)
        XCTAssertNil(run.nextAttemptAt)
    }

    func test_resumeContractReminderCarriesDraftFileInstruction() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .question("Which version?"),
            .completed("Done"),
        ])
        let container = try makeContainer()
        let context = ModelContext(container)
        let contractWithDrafts = """
        Work only on the assigned task.
        Never send email.
        When you produce drafted content, write the full draft to a markdown file at \
        `_agent/drafts/<task-uid>/<slug>.md` and return it in `drafts[]`.
        Return only structured output.
        """
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: { try context.save() },
            contractProvider: { contractWithDrafts },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Draft on resume", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)
        coordinator.reply(to: task, text: "Use 5.2.0", now: secondTurn)
        await coordinator.runNext(settings: settings, now: secondTurn)

        let resumeRequests = await runtime.resumeRequests
        let prompt = try XCTUnwrap(resumeRequests.first).prompt
        XCTAssertTrue(prompt.contains("_agent/drafts/"))
    }

    func test_requestChangesResetsRetryBudgetForFreshTurn() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("First draft")])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Review then revise", stage: .forAgent)
        task.actionType = .vaultNote
        await coordinator.runNext(settings: settings, now: firstTurn)
        task.agentRun?.autoRetryCount = 2
        task.agentRun?.nextAttemptAt = thirdTurn

        coordinator.requestChanges(task, feedback: "Add a caveat", now: secondTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.agentRun?.autoRetryCount, 0)
        XCTAssertNil(task.agentRun?.nextAttemptAt)
    }

    func test_messagesUseMonotonicSequenceAndPinnedTimestamps() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.question("Choose one")])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Ordered", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)
        coordinator.reply(to: task, text: "Option A", now: secondTurn)

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(run.orderedMessages.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(run.orderedMessages.map(\.kind), [.progress, .question, .answer])
        XCTAssertEqual(run.orderedMessages.map(\.createdAt), [firstTurn, secondTurn, secondTurn])
        XCTAssertEqual(run.lastActivityAt, secondTurn)
    }

    func test_unroutableHighestRankedTaskDoesNotStarveRoutableTask() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Routed done")])
        let (coordinator, context) = try fixture(runtime: runtime)
        let unroutable = MustardTask(title: "Urgent but unrouted", owner: .agent)
        unroutable.stage = .forAgent
        unroutable.priority = .urgent
        unroutable.createdAt = Date(timeIntervalSince1970: 1)
        context.insert(unroutable)
        let routed = insertRoutedTask(in: context, title: "Routable", stage: .forAgent, created: 2)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(unroutable.stage, .forAgent)
        XCTAssertNil(unroutable.agentRun)
        XCTAssertEqual(routed.stage, .needsReview)
        let startCount = await runtime.startRequests.count
        XCTAssertEqual(startCount, 1)
    }

    func test_contractLoadFailureLeavesNoPhantomTurnAndRetryStartsFreshSession() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Retried")])
        let container = try makeContainer()
        let context = ModelContext(container)
        var contractCalls = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: { try context.save() },
            contractProvider: {
                contractCalls += 1
                if contractCalls == 1 { throw CocoaError(.fileNoSuchFile) }
                return self.testContract
            },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Contract retry", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .forAgent)
        XCTAssertNil(task.agentRun)
        let firstInvocationCount = await runtime.invocationCount
        XCTAssertEqual(firstInvocationCount, 0)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        let startCount = await runtime.startRequests.count
        let resumeCount = await runtime.resumeRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 0)
    }

    func test_preflightSaveFailureRemovesNewRunSessionProgressAndRetryStarts() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Retried")])
        let container = try makeContainer()
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                saveCount += 1
                if saveCount == 1 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Preflight retry", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .forAgent)
        XCTAssertNil(task.agentRun)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentRun>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentMessage>()).count, 0)
        let firstInvocationCount = await runtime.invocationCount
        XCTAssertEqual(firstInvocationCount, 0)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .needsReview)
        let startCount = await runtime.startRequests.count
        let resumeCount = await runtime.resumeRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 0)
    }

    func test_preflightSaveFailureRestoresExistingRunAndPreservesUnrelatedEdit() async throws {
        let sessionID = "55555555-5555-5555-5555-555555555555"
        let runtime = ScriptedAgentRuntime(knownSessionIDs: [sessionID])
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = false
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Existing preflight", stage: .queued)
        let run = AgentRun(task: task, workingDirectory: "/old/path", project: "Old Project")
        run.state = .failed
        run.providerSessionID = sessionID
        run.attemptCount = 3
        run.resumeCount = 2
        run.startedAt = thirdTurn
        run.completedAt = thirdTurn
        run.lastActivityAt = thirdTurn
        run.lastOutcomeRaw = AgentTurnOutcome.failed.rawValue
        run.lastError = "Old error"
        task.agentRun = run
        context.insert(run)
        let unrelated = MustardTask(title: "Unrelated")
        unrelated.notes = "saved"
        context.insert(unrelated)
        try context.save()
        unrelated.notes = "dirty"
        fail = true

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertTrue(task.agentRun === run)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.providerSessionID, sessionID)
        XCTAssertEqual(run.workingDirectory, "/old/path")
        XCTAssertEqual(run.project, "Old Project")
        XCTAssertEqual(run.attemptCount, 3)
        XCTAssertEqual(run.resumeCount, 2)
        XCTAssertEqual(run.startedAt, thirdTurn)
        XCTAssertEqual(run.completedAt, thirdTurn)
        XCTAssertEqual(run.lastActivityAt, thirdTurn)
        XCTAssertEqual(run.lastOutcomeRaw, AgentTurnOutcome.failed.rawValue)
        XCTAssertEqual(run.lastError, "Old error")
        XCTAssertTrue(run.orderedMessages.isEmpty)
        XCTAssertEqual(unrelated.notes, "dirty")
        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func test_recoveryCheckpointFailureRestoresOldSessionAndNeverStartsReplacement() async throws {
        let oldSession = "33333333-3333-3333-3333-333333333333"
        let runtime = ScriptedAgentRuntime(
            responses: [.failure(.sessionMissing("Lost"))],
            knownSessionIDs: [oldSession]
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                saveCount += 1
                if saveCount == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Recovery checkpoint", stage: .queued)
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        run.providerSessionID = oldSession
        task.agentRun = run
        context.insert(run)
        try context.save()

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(run.providerSessionID, oldSession)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(run.state, .failed)
        let resumedSessionIDs = await runtime.resumeRequests.map(\.sessionID)
        let startCount = await runtime.startRequests.count
        XCTAssertEqual(resumedSessionIDs, [oldSession])
        XCTAssertEqual(startCount, 0)
        XCTAssertFalse(run.orderedMessages.contains {
            $0.content.contains("starting a replacement session")
        })
    }

    func test_transitionClockSeparatesInvocationStartFromOutcome() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Later")])
        let container = try makeContainer()
        let context = ModelContext(container)
        let clock = SequencedTestClock([secondTurn])
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: { try context.save() },
            contractProvider: { self.testContract },
            nowProvider: { clock.next() }
        )
        let task = insertRoutedTask(in: context, title: "Timed", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(run.startedAt, firstTurn)
        XCTAssertEqual(run.orderedMessages.first?.createdAt, firstTurn)
        XCTAssertEqual(run.orderedMessages.last?.createdAt, secondTurn)
        XCTAssertEqual(run.completedAt, secondTurn)
        XCTAssertEqual(run.lastActivityAt, secondTurn)
    }

    func test_recoveryUsesIndependentCheckpointAndOutcomeTimes() async throws {
        let oldSession = "44444444-4444-4444-4444-444444444444"
        let runtime = ScriptedAgentRuntime(
            responses: [.failure(.sessionMissing("Lost")), .completed("Recovered")],
            knownSessionIDs: [oldSession]
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        let clock = SequencedTestClock([secondTurn, thirdTurn])
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: { try context.save() },
            contractProvider: { self.testContract },
            nowProvider: { clock.next() }
        )
        let task = insertRoutedTask(in: context, title: "Timed recovery", stage: .queued)
        let run = AgentRun(task: task)
        run.providerSessionID = oldSession
        task.agentRun = run
        context.insert(run)

        await coordinator.runNext(settings: settings, now: firstTurn)

        let recovery = try XCTUnwrap(run.orderedMessages.first { $0.kind == .recovery })
        let result = try XCTUnwrap(run.orderedMessages.last { $0.kind == .result })
        XCTAssertEqual(recovery.createdAt, secondTurn)
        XCTAssertEqual(result.createdAt, thirdTurn)
        XCTAssertEqual(run.completedAt, thirdTurn)
        XCTAssertEqual(run.lastActivityAt, thirdTurn)
    }

    func test_duplicateReplyRequestChangesAndAcceptAreNoOps() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .question("Answer?"), .completed("Draft"), .completed("Revised"),
        ])
        let (coordinator, context) = try fixture(runtime: runtime)
        let task = insertRoutedTask(in: context, title: "Idempotent commands", stage: .forAgent)
        task.recurrence = .daily
        task.dueAt = firstTurn
        await coordinator.runNext(settings: settings, now: firstTurn)

        coordinator.reply(to: task, text: "One", now: secondTurn)
        let afterReply = try XCTUnwrap(task.agentRun).orderedMessages.count
        coordinator.reply(to: task, text: "Duplicate", now: secondTurn)
        XCTAssertEqual(task.agentRun?.orderedMessages.count, afterReply)
        await coordinator.runNext(settings: settings, now: secondTurn)

        coordinator.requestChanges(task, feedback: "Revise", now: thirdTurn)
        let afterFeedback = try XCTUnwrap(task.agentRun).orderedMessages.count
        coordinator.requestChanges(task, feedback: "Duplicate", now: thirdTurn)
        XCTAssertEqual(task.agentRun?.orderedMessages.count, afterFeedback)
        await coordinator.runNext(settings: settings, now: thirdTurn)

        coordinator.accept(task, now: thirdTurn)
        coordinator.accept(task, now: thirdTurn)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).filter {
            $0.recurredFrom == task.uid
        }.count, 1)
    }

    func test_outcomeSaveFailureCompensatesDurablyAndCanRerun() async throws {
        let runtime = ScriptedAgentRuntime(responses: [
            .completed("First result"), .completed("Second result"),
        ])
        let container = try makeContainer()
        let context = ModelContext(container)
        var saveCount = 0
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                saveCount += 1
                if saveCount == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Compensate", stage: .forAgent)

        await coordinator.runNext(settings: settings, now: firstTurn)

        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.agentRun?.state, .failed)
        XCTAssertEqual(task.agentRun?.orderedMessages.last?.kind, .error)
        let fresh = ModelContext(container)
        let durable = try XCTUnwrap(fresh.fetch(FetchDescriptor<MustardTask>()).first {
            $0.uid == task.uid
        })
        XCTAssertEqual(durable.stage, .queued)
        XCTAssertEqual(durable.agentRun?.state, .failed)

        await coordinator.runNext(settings: settings, now: firstTurn)
        XCTAssertEqual(task.stage, .needsReview)
        let startCount = await runtime.startRequests.count
        let resumeCount = await runtime.resumeRequests.count
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 1)
    }

    func test_acceptSaveFailureRestoresRecurringTaskAndPreservesUnrelatedEdit() throws {
        let runtime = ScriptedAgentRuntime()
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = false
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Recurring", stage: .needsReview)
        task.recurrence = .daily
        task.dueAt = firstTurn
        let unrelated = MustardTask(title: "Unrelated")
        unrelated.notes = "saved"
        context.insert(unrelated)
        try context.save()
        unrelated.notes = "dirty"
        fail = true

        coordinator.accept(task, now: secondTurn)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(unrelated.notes, "dirty")
        XCTAssertTrue(try context.fetch(FetchDescriptor<MustardTask>()).allSatisfy {
            $0.recurredFrom != task.uid
        })
        coordinator.accept(task, now: secondTurn)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).filter {
            $0.recurredFrom == task.uid
        }.count, 1)
    }

    func test_replySaveFailureRestoresGateAndPreservesUnrelatedEdit() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.question("Answer?")])
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = false
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Reply rollback", stage: .forAgent)
        let unrelated = MustardTask(title: "Unrelated")
        unrelated.notes = "saved"
        context.insert(unrelated)
        await coordinator.runNext(settings: settings, now: firstTurn)
        unrelated.notes = "dirty"
        fail = true
        let oldCount = try XCTUnwrap(task.agentRun).orderedMessages.count

        coordinator.reply(to: task, text: "Answer", now: thirdTurn)

        XCTAssertEqual(task.stage, .needsInput)
        XCTAssertEqual(task.agentRun?.state, .needsInput)
        XCTAssertEqual(task.agentRun?.orderedMessages.count, oldCount)
        XCTAssertEqual(unrelated.notes, "dirty")
    }

    func test_takeBackSaveFailureDoesNotCancelOrInvalidateActiveTurn() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Late success")],
            suspendNextInvocation: true
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = false
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Failed take back", stage: .forAgent)
        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        fail = true

        coordinator.takeBack(task, now: secondTurn)

        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .inProgress)
        XCTAssertEqual(task.agentRun?.state, .running)
        let cancelCount = await runtime.cancelCount
        XCTAssertEqual(cancelCount, 0)
        await runtime.releaseInvocation()
        await active.value
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_cancelActiveSaveFailureDoesNotCancelOrInvalidateActiveTurn() async throws {
        let runtime = ScriptedAgentRuntime(
            responses: [.completed("Late success")],
            suspendNextInvocation: true
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        var fail = false
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            persist: {
                if fail { fail = false; throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            contractProvider: { self.testContract },
            nowProvider: { self.secondTurn }
        )
        let task = insertRoutedTask(in: context, title: "Failed cancel", stage: .forAgent)
        let active = Task { await coordinator.runNext(settings: settings, now: firstTurn) }
        await waitForInvocation(runtime)
        fail = true

        coordinator.cancelActive()

        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .inProgress)
        XCTAssertEqual(task.agentRun?.state, .running)
        let cancelCount = await runtime.cancelCount
        XCTAssertEqual(cancelCount, 0)
        await runtime.releaseInvocation()
        await active.value
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_retryAuthenticationIgnoresOlderHealthResultThatFinishesLast() async throws {
        let runtime = ScriptedAgentRuntime(
            healthResponses: [.unavailable("old failure"), .available],
            controlHealthResponses: true
        )
        let (coordinator, _) = try fixture(runtime: runtime)

        let older = Task { await coordinator.retryAuthentication() }
        await waitForHealth(runtime, count: 1)
        let newer = Task { await coordinator.retryAuthentication() }
        await waitForHealth(runtime, count: 2)
        await runtime.releaseHealth(1)
        await newer.value
        await runtime.releaseHealth(0)
        await older.value

        XCTAssertFalse(coordinator.authenticationRequired)
        XCTAssertNil(coordinator.lastError)
    }

    func test_noTaskDoesNotCallRuntime() async throws {
        let runtime = ScriptedAgentRuntime(responses: [.completed("Unused")])
        let (coordinator, _) = try fixture(runtime: runtime)

        await coordinator.runNext(settings: settings, now: firstTurn)

        let invocationCount = await runtime.invocationCount
        XCTAssertEqual(invocationCount, 0)
        XCTAssertFalse(coordinator.isRunning)
    }

    private var settings: SourceSettings {
        SourceSettings(
            sources: [
                SourceConfig(
                    id: .vault,
                    project: "DL-Knowledge-Base",
                    enabled: true,
                    workingDirectory: "/kb/DL"
                ),
            ],
            state: []
        )
    }

    private var testContract: String {
        "Work only on the assigned task.\nNever send email.\nReturn only structured output."
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func fixture(
        runtime: ScriptedAgentRuntime
    ) throws -> (AgentTaskCoordinator, ModelContext) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        return (
            AgentTaskCoordinator(
                context: context,
                runtime: runtime,
                persist: { try context.save() },
                contractProvider: { self.testContract },
                nowProvider: { self.secondTurn }
            ),
            context
        )
    }

    @discardableResult
    private func insertRoutedTask(
        in context: ModelContext,
        title: String,
        stage: TaskStage,
        created: TimeInterval = 0
    ) -> MustardTask {
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "Work", area: area)
        let task = MustardTask(title: title, owner: .agent)
        task.stage = stage
        task.createdAt = Date(timeIntervalSince1970: created)
        task.list = list
        context.insert(area)
        context.insert(list)
        context.insert(task)
        return task
    }

    private func waitForInvocation(
        _ runtime: ScriptedAgentRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            let invocationCount = await runtime.invocationCount
            if invocationCount > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for runtime invocation", file: file, line: line)
    }

    private func waitForCancel(
        _ runtime: ScriptedAgentRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            let cancelCount = await runtime.cancelCount
            if cancelCount > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for runtime cancellation", file: file, line: line)
    }

    private func waitForHealth(
        _ runtime: ScriptedAgentRuntime,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await runtime.healthCount >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for runtime health call", file: file, line: line)
    }
}
