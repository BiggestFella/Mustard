import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class AgentTaskCoordinator {
    private struct TaskSnapshot {
        let stage: TaskStage
        let status: TaskStatus
        let owner: TaskOwner
        let links: [TaskLink]
        let completedAt: Date?
        let autoCompleted: Bool
        let agentRun: AgentRun?
    }

    private struct RunSnapshot {
        let state: AgentRunState
        let providerSessionID: String?
        let workingDirectory: String
        let project: String
        let attemptCount: Int
        let resumeCount: Int
        let startedAt: Date?
        let lastActivityAt: Date
        let completedAt: Date?
        let lastOutcomeRaw: String?
        let lastError: String?
        let requiresConnectedWorker: Bool
        let nextAttemptAt: Date?
        let autoRetryCount: Int
    }

    public private(set) var isRunning = false
    public private(set) var activeTitle: String?
    public private(set) var authenticationRequired = false
    public private(set) var lastError: String?

    private let context: ModelContext
    private let runtime: any AgentRuntime
    private let executionGate: AgentExecutionGate
    private let persist: () throws -> Void
    private let contractProvider: () throws -> String
    private let nowProvider: () -> Date
    /// Fallback route for area-less agent tasks (F26). Injected so tests can pin it;
    /// in the app it resolves the meeting vault ("Codeheroes work") as the default KB.
    private let defaultRouteProvider: () -> AgentTaskRoute?
    private var activeTask: MustardTask?
    private var activeRun: AgentRun?
    private var activeGeneration = 0
    private var cancellationTask: Task<Void, Never>?
    private var authenticationGeneration = 0

    public init(
        context: ModelContext,
        runtime: any AgentRuntime = ClaudeTaskRuntime(),
        executionGate: AgentExecutionGate? = nil
    ) {
        self.context = context
        self.runtime = runtime
        self.executionGate = executionGate ?? AgentExecutionGate()
        self.persist = { try context.save() }
        self.contractProvider = AgentTurnContract.workerContract
        self.nowProvider = { Date.now }
        self.defaultRouteProvider = AgentTaskCoordinator.meetingVaultDefaultRoute
    }

    init(
        context: ModelContext,
        runtime: any AgentRuntime,
        executionGate: AgentExecutionGate? = nil,
        persist: @escaping () throws -> Void,
        contractProvider: @escaping () throws -> String = AgentTurnContract.workerContract,
        nowProvider: @escaping () -> Date = { Date.now },
        defaultRouteProvider: @escaping () -> AgentTaskRoute? = AgentTaskCoordinator.meetingVaultDefaultRoute
    ) {
        self.context = context
        self.runtime = runtime
        self.executionGate = executionGate ?? AgentExecutionGate()
        self.persist = persist
        self.contractProvider = contractProvider
        self.nowProvider = nowProvider
        self.defaultRouteProvider = defaultRouteProvider
    }

    /// The default agent KB for area-less hand-offs: the meeting vault ("Codeheroes
    /// work"), filed under the `Code Heroes` project. Nil when no meeting vault is set
    /// — an area-less task then simply stays queued rather than routing nowhere.
    nonisolated static func meetingVaultDefaultRoute() -> AgentTaskRoute? {
        let path = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentTaskRoute(project: "Code Heroes", workingDirectory: path)
    }

    public func runNext(settings: SourceSettings, now: Date = .now) async {
        guard !isRunning, !authenticationRequired else { return }
        guard let executionToken = executionGate.tryAcquire(owner: "delegated task") else { return }
        defer { executionGate.release(executionToken) }

        let tasks: [MustardTask]
        do {
            tasks = try context.fetch(FetchDescriptor<MustardTask>())
        } catch {
            lastError = "Could not load the agent task queue: \(error.localizedDescription)"
            return
        }

        guard let (task, route) = nextRoutableTask(in: tasks, settings: settings, now: now) else {
            return
        }

        let contract: String
        do {
            contract = try contractProvider()
        } catch {
            lastError = "Could not load the worker contract: \(error.localizedDescription)"
            return
        }

        isRunning = true
        activeTitle = task.title
        lastError = nil
        activeGeneration += 1
        let generation = activeGeneration

        let taskBeforePreflight = taskSnapshot(task)
        let existingRun = task.agentRun
        let runBeforePreflight = existingRun.map(runSnapshot)
        let run = ensureRun(for: task)
        activeTask = task
        activeRun = run
        defer {
            isRunning = false
            activeTitle = nil
            activeTask = nil
            activeRun = nil
        }

        run.project = route.project
        run.workingDirectory = route.workingDirectory
        let startsNewSession = run.providerSessionID == nil
        if startsNewSession {
            run.providerSessionID = UUID().uuidString
        }

        task.stage = .inProgress
        run.state = .running
        run.requiresConnectedWorker = false
        run.nextAttemptAt = nil   // picking it up now clears any scheduled backoff
        run.startedAt = run.startedAt ?? now
        run.completedAt = nil
        run.lastError = nil
        run.attemptCount += 1
        if !startsNewSession { run.resumeCount += 1 }
        let progressMessage = append(
            to: run,
            role: .system,
            kind: .progress,
            content: startsNewSession ? "Agent started work." : "Agent resumed work.",
            now: now
        )

        guard save("Could not persist the agent turn before execution") else {
            let persistenceError = lastError
            restorePreflight(
                task: task,
                taskSnapshot: taskBeforePreflight,
                run: run,
                runSnapshot: runBeforePreflight,
                wasNewRun: existingRun == nil,
                progressMessage: progressMessage
            )
            lastError = persistenceError
            return
        }

        let sessionID = run.providerSessionID ?? UUID().uuidString
        let prompt: String
        let response: AgentRuntimeResponse
        if startsNewSession {
            prompt = AgentTaskPrompt.firstTurn(
                task: task,
                run: run,
                contract: contract,
                approvedInstructions: []
            )
            response = await runtime.start(.init(
                sessionID: sessionID,
                prompt: prompt,
                workingDirectory: route.workingDirectory
            ))
        } else {
            prompt = AgentTaskPrompt.resume(
                run: run,
                latestHumanMessage: latestHumanContent(in: run, fallback: task.title),
                contractReminder: contractReminder(from: contract),
                approvedInstructions: []
            )
            response = await runtime.resume(.init(
                sessionID: sessionID,
                prompt: prompt,
                workingDirectory: route.workingDirectory
            ))
        }
        let responseTime = nowProvider()

        await drainPendingCancellation()
        guard isCurrent(task: task, run: run, generation: generation) else { return }

        if case .sessionMissing(let detail)? = response.failure {
            await recoverMissingSession(
                task: task,
                run: run,
                route: route,
                contract: contract,
                detail: detail,
                generation: generation,
                now: responseTime
            )
            return
        }

        apply(response, to: task, run: run, generation: generation, now: responseTime)
    }

    public func reply(to task: MustardTask, text: String, now: Date = .now) {
        queueHumanTurn(task, text: text, kind: .answer, now: now)
    }

    public func requestChanges(
        _ task: MustardTask,
        feedback: String,
        now: Date = .now
    ) {
        queueHumanTurn(task, text: feedback, kind: .reviewFeedback, now: now)
    }

    public func accept(_ task: MustardTask, now: Date = .now) {
        guard task.stage == .needsReview else { return }
        let family = completionFamily(of: task)
        let snapshots = family.map { ($0, taskSnapshot($0)) }
        let existingUIDs: Set<String>
        do {
            existingUIDs = Set(try context.fetch(FetchDescriptor<MustardTask>()).map(\.uid))
        } catch {
            lastError = "Could not prepare task acceptance: \(error.localizedDescription)"
            return
        }
        TaskCompletion.complete(task, in: context, now: now)
        guard save("Could not save the accepted task") else {
            let persistenceError = lastError
            for (member, snapshot) in snapshots {
                restore(member, from: snapshot)
            }
            if let tasks = try? context.fetch(FetchDescriptor<MustardTask>()) {
                for inserted in tasks where !existingUIDs.contains(inserted.uid) {
                    context.delete(inserted)
                }
            }
            lastError = persistenceError
            return
        }
    }

    public func takeBack(_ task: MustardTask, now: Date = .now) {
        let legalStages: Set<TaskStage> = [
            .inbox, .forAgent, .needsApproval, .queued, .inProgress, .needsInput, .needsReview,
        ]
        guard task.owner == .agent, legalStages.contains(task.stage) else { return }
        guard persistLocalCancellation(
            task: task,
            run: task.agentRun,
            detail: "Task taken back by you; active agent work was cancelled.",
            now: now,
            savePrefix: "Could not save the taken-back task"
        ) else { return }

        if activeTask === task {
            activeGeneration += 1
            requestRuntimeCancellation()
        }
    }

    public func cancelActive() {
        guard let task = activeTask, let run = activeRun else { return }
        guard task.owner == .agent,
              task.stage == .inProgress,
              run.state == .running,
              persistLocalCancellation(
                task: task,
                run: run,
                detail: "Active agent work was cancelled by you.",
                now: nowProvider(),
                savePrefix: "Could not save the cancelled agent turn"
              )
        else { return }
        activeGeneration += 1
        requestRuntimeCancellation()
    }

    public func retryAuthentication() async {
        authenticationGeneration += 1
        let generation = authenticationGeneration
        let health = await runtime.health()
        guard generation == authenticationGeneration else { return }
        switch health {
        case .available:
            authenticationRequired = false
            lastError = nil
        case .authenticationRequired(let detail), .unavailable(let detail):
            authenticationRequired = true
            lastError = detail.isEmpty
                ? "The agent runtime is still unavailable."
                : detail
        }
    }

    /// Reconcile runs left `.running` by an app that stopped mid-turn back to the queue.
    /// Returns `false` on a fetch or save failure so the caller (the launch scheduler) can
    /// retry on a later tick. A failed save narrowly restores only the runs/tasks/messages
    /// this pass touched — never a broad rollback — so unrelated dirty edits survive and a
    /// retry does not append duplicate recovery messages.
    @discardableResult
    public func reconcileInterruptedRuns(now: Date = .now) -> Bool {
        let runs: [AgentRun]
        do {
            runs = try context.fetch(FetchDescriptor<AgentRun>())
        } catch {
            lastError = "Could not reconcile interrupted agent runs: \(error.localizedDescription)"
            return false
        }

        var touched: [(run: AgentRun, runBefore: RunSnapshot, task: MustardTask?, taskBefore: TaskSnapshot?, message: AgentMessage)] = []
        for run in runs where run.state == .running {
            let runBefore = runSnapshot(run)
            let task = run.task
            let taskBefore = task.map(taskSnapshot)
            run.state = .interrupted
            run.lastError = "The app stopped while this agent turn was running."

            // A gated (ticket/draft) turn may have created an external artifact before the
            // app stopped; whether it did is unknown, so route it to review rather than
            // silently re-running it. Local work returns straight to the queue.
            let content: String
            if let task, task.owner == .agent, task.stage == .inProgress,
               task.actionType?.isGated == true {
                task.stage = .needsReview
                run.completedAt = now
                content = "Recovered an interrupted run. Completion uncertain — check whether the external artifact exists before requesting a retry."
            } else {
                if let task, task.owner == .agent, task.stage == .inProgress {
                    task.stage = .queued
                }
                run.completedAt = nil
                content = "Recovered an interrupted run and returned it to the queue."
            }
            let message = append(
                to: run,
                role: .system,
                kind: .recovery,
                content: content,
                now: now
            )
            touched.append((run, runBefore, task, taskBefore, message))
        }

        guard save("Could not save interrupted-run recovery") else {
            let persistenceError = lastError
            for entry in touched {
                restore(entry.run, from: entry.runBefore)
                if let task = entry.task, let taskBefore = entry.taskBefore {
                    restore(task, from: taskBefore)
                }
                remove(entry.message, from: entry.run)
            }
            lastError = persistenceError
            return false
        }
        return true
    }

    private func recoverMissingSession(
        task: MustardTask,
        run: AgentRun,
        route: AgentTaskRoute,
        contract: String,
        detail: String,
        generation: Int,
        now: Date
    ) async {
        guard isCurrent(task: task, run: run, generation: generation) else { return }

        let runBeforeRecovery = runSnapshot(run)
        let replacementSessionID = UUID().uuidString
        run.providerSessionID = replacementSessionID
        run.attemptCount += 1
        let recoveryMessage = append(
            to: run,
            role: .system,
            kind: .recovery,
            content: "Provider session was unavailable; starting a replacement session. \(detail)",
            now: now
        )
        guard save("Could not persist provider-session recovery") else {
            let persistenceError = lastError
                ?? "Could not persist provider-session recovery."
            restore(run, from: runBeforeRecovery)
            remove(recoveryMessage, from: run)
            compensatePersistenceFailure(
                task: task,
                run: run,
                detail: persistenceError,
                now: now,
                kind: .error
            )
            return
        }

        let recoveryPrompt = AgentTaskPrompt.recovery(
            task: task,
            run: run,
            contract: contract,
            approvedInstructions: []
        )
        let recoveryResponse = await runtime.start(.init(
            sessionID: replacementSessionID,
            prompt: recoveryPrompt,
            workingDirectory: route.workingDirectory
        ))
        let recoveryResponseTime = nowProvider()

        await drainPendingCancellation()
        guard isCurrent(task: task, run: run, generation: generation) else { return }
        apply(
            recoveryResponse,
            to: task,
            run: run,
            generation: generation,
            now: recoveryResponseTime
        )
    }

    private func apply(
        _ response: AgentRuntimeResponse,
        to task: MustardTask,
        run: AgentRun,
        generation: Int,
        now: Date
    ) {
        guard isCurrent(task: task, run: run, generation: generation) else { return }

        if let result = response.result {
            apply(result, to: task, run: run, now: now)
            return
        }
        guard let failure = response.failure else {
            restoreFailedTurn(
                task: task,
                run: run,
                detail: "The agent runtime returned neither a result nor a failure.",
                now: now,
                kind: .error
            )
            return
        }

        switch failure {
        case .authenticationRequired(let detail):
            pauseForAuthentication(
                message: detail.isEmpty ? "Agent authentication is required." : detail,
                task: task,
                run: run,
                now: now
            )

        case .cancelled(let detail):
            let message = detail.isEmpty
                ? "The agent runtime cancelled the turn."
                : detail
            apply(
                AgentTurnResult(
                    outcome: .cancelled,
                    message: message,
                    questions: [],
                    summary: message,
                    artifacts: [],
                    retryDisposition: .none,
                    errorCategory: nil,
                    connectedCapability: nil
                ),
                to: task,
                run: run,
                now: now
            )

        case .rateLimited(let detail):
            applyRecoverableFailure(failure, description: failureDescription("Rate limited", detail), task: task, run: run, now: now)
        case .timedOut(let detail):
            applyRecoverableFailure(failure, description: failureDescription("Timed out", detail), task: task, run: run, now: now)
        case .sessionMissing(let detail):
            // The sole recovery attempt has already been consumed before this path.
            applyRecoverableFailure(failure, description: failureDescription("Replacement session missing", detail), task: task, run: run, now: now)
        case .malformedOutput(let detail):
            applyRecoverableFailure(failure, description: failureDescription("Malformed agent output", detail), task: task, run: run, now: now)
        case .process(let detail):
            applyRecoverableFailure(failure, description: failureDescription("Agent process failed", detail), task: task, run: run, now: now)
        }
    }

    private func pauseForAuthentication(
        message: String,
        task: MustardTask,
        run: AgentRun,
        now: Date
    ) {
        authenticationRequired = true
        lastError = message
        task.stage = .queued
        run.state = .queued
        run.completedAt = nil
        run.lastError = message
        append(to: run, role: .system, kind: .error, content: message, now: now)
        _ = save("Could not save the authentication pause")
    }

    /// Apply the pure `AgentRetryPolicy` to a failed turn: pause on auth, requeue with a
    /// bounded backoff for safe local work, send outward-artifact ambiguity to review as
    /// completion-uncertain, or surface a terminal failure once retries are exhausted.
    /// Only acts on the still-current running turn; narrow save, no broad rollback.
    private func applyRecoverableFailure(
        _ failure: AgentRuntimeFailure,
        description: String,
        task: MustardTask,
        run: AgentRun,
        now: Date
    ) {
        guard task.owner == .agent,
              task.stage == .inProgress,
              run.state == .running
        else { return }

        switch AgentRetryPolicy.action(for: failure, action: task.actionType, retryCount: run.autoRetryCount) {
        case .pauseRuntime:
            pauseForAuthentication(message: description, task: task, run: run, now: now)

        case .retryAfter(let seconds):
            run.autoRetryCount += 1
            run.nextAttemptAt = now.addingTimeInterval(seconds)
            task.stage = .queued
            run.state = .failed
            run.completedAt = now
            run.lastOutcomeRaw = nil
            run.lastError = description
            lastError = description
            append(
                to: run,
                role: .system,
                kind: .error,
                content: "\(description). Retrying automatically (attempt \(run.autoRetryCount)).",
                now: now
            )
            _ = save("Could not save the retry schedule")

        case .completionUncertain:
            task.stage = .needsReview
            run.state = .failed
            run.completedAt = now
            run.nextAttemptAt = nil
            run.lastOutcomeRaw = nil
            run.lastError = description
            lastError = description
            append(
                to: run,
                role: .agent,
                kind: .error,
                content: "Completion uncertain — check whether the external artifact exists before requesting a retry. (\(description))",
                now: now
            )
            _ = save("Could not save the completion-uncertain review")

        case .fail:
            task.stage = .needsReview
            run.state = .failed
            run.completedAt = now
            run.nextAttemptAt = nil
            run.lastOutcomeRaw = nil
            run.lastError = description
            lastError = description
            append(
                to: run,
                role: .system,
                kind: .error,
                content: "\(description). Automatic retries exhausted — review needed.",
                now: now
            )
            _ = save("Could not save the failed agent turn")
        }
    }

    private func apply(
        _ result: AgentTurnResult,
        to task: MustardTask,
        run: AgentRun,
        now: Date
    ) {
        let taskBeforeOutcome = taskSnapshot(task)
        let runBeforeOutcome = runSnapshot(run)

        let decision = AgentTaskTransition.decision(for: result.outcome)
        task.stage = decision.taskStage
        if let owner = decision.taskOwner { task.owner = owner }
        run.state = decision.runState
        run.requiresConnectedWorker = decision.requiresConnectedWorker
        run.lastOutcomeRaw = result.outcome.rawValue
        run.lastError = nil

        let outcomeMessage: AgentMessage
        switch result.outcome {
        case .needsInput:
            run.completedAt = nil
            let questions = result.questions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            outcomeMessage = append(
                to: run,
                role: .agent,
                kind: .question,
                content: questions.isEmpty ? result.message : questions,
                now: now
            )

        case .completed:
            run.completedAt = now
            let links = result.artifacts.map { TaskLink(label: $0.label, url: $0.url) }
            merge(links, into: task)
            outcomeMessage = append(
                to: run,
                role: .agent,
                kind: .result,
                content: result.summary.isEmpty ? result.message : result.summary,
                links: links,
                now: now
            )

        case .failed:
            // A model-reported failure must NOT sit at the transition's default `.queued`
            // (immediately runnable → the 2s tick would loop it forever, uncapped). Honor
            // the agent's retry disposition under the same bounded backoff/cap as runtime
            // failures; otherwise send it to Needs Review for a human (who can Request
            // changes to requeue with feedback).
            run.completedAt = now
            let category = result.errorCategory ?? "Agent task failed"
            let detail = result.message.isEmpty ? category : "\(category): \(result.message)"
            run.lastError = detail
            lastError = detail
            let wantsRetry = result.retryDisposition == .safe || result.retryDisposition == .backoff
            if wantsRetry, run.autoRetryCount < AgentRetryPolicy.backoffSeconds.count {
                let seconds = AgentRetryPolicy.backoffSeconds[run.autoRetryCount]
                run.autoRetryCount += 1
                run.nextAttemptAt = now.addingTimeInterval(seconds)
                task.stage = .queued
                run.state = .failed
                outcomeMessage = append(
                    to: run,
                    role: .agent,
                    kind: .error,
                    content: "\(detail). Retrying automatically (attempt \(run.autoRetryCount)).",
                    now: now
                )
            } else {
                task.stage = .needsReview
                run.state = .failed
                run.nextAttemptAt = nil
                outcomeMessage = append(
                    to: run,
                    role: .agent,
                    kind: .error,
                    content: detail,
                    now: now
                )
            }

        case .cancelled:
            run.completedAt = now
            outcomeMessage = append(
                to: run,
                role: .agent,
                kind: .recovery,
                content: result.message.isEmpty ? "The agent cancelled this task." : result.message,
                now: now
            )

        case .requiresConnectedWorker:
            run.completedAt = nil
            let capability = result.connectedCapability ?? "a connected capability"
            let detail = result.message.isEmpty
                ? "Connected worker required: \(capability)."
                : result.message
            outcomeMessage = append(
                to: run,
                role: .agent,
                kind: .recovery,
                content: detail,
                now: now
            )
        }

        let createdDrafts = AgentConversation.materializeDrafts(result.drafts ?? [], into: run, in: context)

        guard save("Could not save the agent turn result") else {
            let persistenceError = lastError
                ?? "Could not save the agent turn result."
            restore(task, from: taskBeforeOutcome)
            restore(run, from: runBeforeOutcome)
            remove(outcomeMessage, from: run)
            for draft in createdDrafts { draft.run = nil; context.delete(draft) }
            compensatePersistenceFailure(
                task: task,
                run: run,
                detail: persistenceError,
                now: now,
                kind: .error
            )
            return
        }
    }

    private func queueHumanTurn(
        _ task: MustardTask,
        text: String,
        kind: AgentMessageKind,
        now: Date
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "A reply cannot be empty."
            return
        }
        guard let run = task.agentRun else {
            lastError = "This task has no agent run to resume."
            return
        }
        let isLegal: Bool
        switch kind {
        case .answer:
            isLegal = task.owner == .agent
                && task.stage == .needsInput
                && run.state == .needsInput
        case .reviewFeedback:
            // Any Needs Review task can be sent back for changes — including a
            // completion-uncertain one whose run ended `.failed` rather than `.completed`.
            isLegal = task.owner == .agent
                && task.stage == .needsReview
        default:
            isLegal = false
        }
        guard isLegal else { return }

        let taskBeforeCommand = taskSnapshot(task)
        let runBeforeCommand = runSnapshot(run)
        let message = append(to: run, role: .human, kind: kind, content: trimmed, now: now)
        task.owner = .agent
        task.stage = .queued
        run.state = .queued
        run.requiresConnectedWorker = false
        run.completedAt = nil
        run.lastError = nil
        // A human-driven turn is a fresh attempt: clear any backoff and retry budget.
        run.nextAttemptAt = nil
        run.autoRetryCount = 0
        lastError = nil
        guard save("Could not save the agent reply") else {
            let persistenceError = lastError
            restore(task, from: taskBeforeCommand)
            restore(run, from: runBeforeCommand)
            remove(message, from: run)
            lastError = persistenceError
            return
        }
    }

    private func ensureRun(for task: MustardTask) -> AgentRun {
        if let run = task.agentRun { return run }
        let run = AgentRun(task: task)
        task.agentRun = run
        context.insert(run)
        return run
    }

    private func nextRoutableTask(
        in tasks: [MustardTask],
        settings: SourceSettings,
        now: Date
    ) -> (MustardTask, AgentTaskRoute)? {
        var remaining = tasks
        var unroutableTitles: [String] = []
        let defaultRoute = defaultRouteProvider()
        while let candidate = AgentTaskQueue.nextRunnable(remaining, now: now) {
            if let route = AgentTaskQueue.route(candidate, settings: settings, defaultRoute: defaultRoute) {
                return (candidate, route)
            }
            unroutableTitles.append(candidate.title)
            remaining.removeAll { $0 === candidate }
        }
        if let first = unroutableTitles.first {
            let suffix = unroutableTitles.count == 1
                ? ""
                : " and \(unroutableTitles.count - 1) other task(s)"
            lastError = "No enabled agent route is configured for “\(first)”\(suffix)."
        }
        return nil
    }

    private func taskSnapshot(_ task: MustardTask) -> TaskSnapshot {
        TaskSnapshot(
            stage: task.stage,
            status: task.status,
            owner: task.owner,
            links: task.links,
            completedAt: task.completedAt,
            autoCompleted: task.autoCompleted,
            agentRun: task.agentRun
        )
    }

    private func runSnapshot(_ run: AgentRun) -> RunSnapshot {
        RunSnapshot(
            state: run.state,
            providerSessionID: run.providerSessionID,
            workingDirectory: run.workingDirectory,
            project: run.project,
            attemptCount: run.attemptCount,
            resumeCount: run.resumeCount,
            startedAt: run.startedAt,
            lastActivityAt: run.lastActivityAt,
            completedAt: run.completedAt,
            lastOutcomeRaw: run.lastOutcomeRaw,
            lastError: run.lastError,
            requiresConnectedWorker: run.requiresConnectedWorker,
            nextAttemptAt: run.nextAttemptAt,
            autoRetryCount: run.autoRetryCount
        )
    }

    private func restore(_ task: MustardTask, from snapshot: TaskSnapshot) {
        task.stage = snapshot.stage
        task.status = snapshot.status
        task.owner = snapshot.owner
        task.links = snapshot.links
        task.completedAt = snapshot.completedAt
        task.autoCompleted = snapshot.autoCompleted
        task.agentRun = snapshot.agentRun
    }

    private func restore(_ run: AgentRun, from snapshot: RunSnapshot) {
        run.state = snapshot.state
        run.providerSessionID = snapshot.providerSessionID
        run.workingDirectory = snapshot.workingDirectory
        run.project = snapshot.project
        run.attemptCount = snapshot.attemptCount
        run.resumeCount = snapshot.resumeCount
        run.startedAt = snapshot.startedAt
        run.lastActivityAt = snapshot.lastActivityAt
        run.completedAt = snapshot.completedAt
        run.lastOutcomeRaw = snapshot.lastOutcomeRaw
        run.lastError = snapshot.lastError
        run.requiresConnectedWorker = snapshot.requiresConnectedWorker
        run.nextAttemptAt = snapshot.nextAttemptAt
        run.autoRetryCount = snapshot.autoRetryCount
    }

    private func remove(_ message: AgentMessage, from run: AgentRun) {
        run.messages = run.messages?.filter { $0 !== message }
        message.run = nil
        context.delete(message)
    }

    private func restorePreflight(
        task: MustardTask,
        taskSnapshot: TaskSnapshot,
        run: AgentRun,
        runSnapshot: RunSnapshot?,
        wasNewRun: Bool,
        progressMessage: AgentMessage
    ) {
        remove(progressMessage, from: run)
        restore(task, from: taskSnapshot)
        if let runSnapshot {
            restore(run, from: runSnapshot)
        } else if wasNewRun {
            run.task = nil
            context.delete(run)
        }
    }

    private func completionFamily(of task: MustardTask) -> [MustardTask] {
        [task] + (task.subtasks ?? []).flatMap(completionFamily)
    }

    private func persistLocalCancellation(
        task: MustardTask,
        run: AgentRun?,
        detail: String,
        now: Date,
        savePrefix: String
    ) -> Bool {
        let taskBefore = taskSnapshot(task)
        let runBefore = run.map(runSnapshot)
        task.owner = .me
        task.stage = .planned
        var message: AgentMessage?
        if let run {
            run.state = .cancelled
            run.requiresConnectedWorker = false
            run.completedAt = now
            run.lastOutcomeRaw = AgentTurnOutcome.cancelled.rawValue
            run.lastError = nil
            // Clear any scheduled backoff/retry budget so a later re-delegation is a clean
            // slate rather than inheriting a stale wait window or a truncated retry cap.
            run.nextAttemptAt = nil
            run.autoRetryCount = 0
            message = append(
                to: run,
                role: .system,
                kind: .recovery,
                content: detail,
                now: now
            )
        }
        guard save(savePrefix) else {
            let persistenceError = lastError
            restore(task, from: taskBefore)
            if let run, let runBefore { restore(run, from: runBefore) }
            if let message, let run { remove(message, from: run) }
            lastError = persistenceError
            return false
        }
        return true
    }

    private func compensatePersistenceFailure(
        task: MustardTask,
        run: AgentRun,
        detail: String,
        now: Date,
        kind: AgentMessageKind
    ) {
        task.owner = .agent
        task.stage = .queued
        run.state = .failed
        run.requiresConnectedWorker = false
        run.completedAt = now
        run.lastOutcomeRaw = nil
        run.lastError = detail
        lastError = detail
        append(to: run, role: .system, kind: kind, content: detail, now: now)
        if !save("Could not persist recovery from an agent persistence failure") {
            // Intentionally retain the recoverable in-memory state even when storage
            // remains unavailable; never expose a released running turn.
            run.lastError = lastError
        }
    }

    @discardableResult
    private func append(
        to run: AgentRun,
        role: AgentMessageRole,
        kind: AgentMessageKind,
        content: String,
        links: [TaskLink] = [],
        now: Date
    ) -> AgentMessage {
        AgentConversation.append(
            to: run,
            role: role,
            kind: kind,
            content: content,
            links: links,
            now: now,
            in: context
        )
    }

    private func restoreFailedTurn(
        task: MustardTask,
        run: AgentRun,
        detail: String,
        now: Date,
        kind: AgentMessageKind
    ) {
        guard task.owner == .agent,
              task.stage == .inProgress,
              run.state == .running
        else { return }

        task.stage = .queued
        run.state = .failed
        run.completedAt = now
        run.lastOutcomeRaw = nil
        run.lastError = detail
        lastError = detail
        append(to: run, role: .system, kind: kind, content: detail, now: now)
        _ = save("Could not save the failed agent turn")
    }

    private func isCurrent(
        task: MustardTask,
        run: AgentRun,
        generation: Int
    ) -> Bool {
        activeGeneration == generation
            && activeTask === task
            && activeRun === run
            && task.owner == .agent
            && task.stage == .inProgress
            && run.state == .running
    }

    private func latestHumanContent(in run: AgentRun, fallback: String) -> String {
        run.orderedMessages.reversed().first {
            $0.role == .human && ($0.kind == .answer || $0.kind == .reviewFeedback)
        }?.content
            ?? run.orderedMessages.reversed().first { $0.role == .human }?.content
            ?? fallback
    }

    private func contractReminder(from contract: String) -> String {
        let prefixes = [
            "Work only", "Ask focused", "Never ", "Verify every", "Every completed",
            "Return only", "Mustard task UID", "The coordinator",
            "When you produce drafted",
        ]
        let selected = contract
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                prefixes.contains { line.hasPrefix($0) }
                    || line.contains("Never send email")
                    // Resumed sessions predate or may have drifted from the drafts
                    // convention, so the file-path + drafts[] lines must survive
                    // into the compact reminder.
                    || line.contains("_agent/drafts/")
            }
        return selected.isEmpty
            ? "Follow the binding worker safety and structured-output contract from the first turn."
            : selected.joined(separator: "\n")
    }

    private func merge(_ links: [TaskLink], into task: MustardTask) {
        var seen = Set(task.links.map { "\($0.label)\u{0}\($0.url)" })
        for link in links where seen.insert("\(link.label)\u{0}\(link.url)").inserted {
            task.links.append(link)
        }
    }

    private func failureDescription(_ prefix: String, _ detail: String) -> String {
        detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? prefix
            : "\(prefix): \(detail)"
    }

    @discardableResult
    private func save(_ prefix: String) -> Bool {
        do {
            try persist()
            return true
        } catch {
            lastError = "\(prefix): \(error.localizedDescription)"
            return false
        }
    }

    private func requestRuntimeCancellation() {
        guard cancellationTask == nil else { return }
        let runtime = runtime
        cancellationTask = Task {
            await runtime.cancel()
        }
    }

    private func drainPendingCancellation() async {
        guard let cancellationTask else { return }
        await cancellationTask.value
        self.cancellationTask = nil
    }
}
