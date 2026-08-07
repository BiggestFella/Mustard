import XCTest
import SwiftData
@testable import MustardKit

private actor GateClaudeProbe {
    private let result: ClaudeResult
    private var shouldSuspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0

    init(result: ClaudeResult, suspend: Bool = false) {
        self.result = result
        self.shouldSuspend = suspend
    }

    func run(_ prompt: String, _ workingDirectory: String) async -> ClaudeResult {
        invocationCount += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GateRuntimeProbe: AgentRuntime {
    private var suspendInvocation: Bool
    private var suspendCancellation: Bool
    private var invocationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0
    private(set) var cancellationCount = 0

    init(suspendInvocation: Bool = false, suspendCancellation: Bool = false) {
        self.suspendInvocation = suspendInvocation
        self.suspendCancellation = suspendCancellation
    }

    func start(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        await invoke()
    }

    func resume(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        await invoke()
    }

    func cancel() async {
        cancellationCount += 1
        if suspendCancellation {
            suspendCancellation = false
            await withCheckedContinuation { cancellationContinuation = $0 }
        }
    }

    func health() async -> AgentRuntimeHealth { .available }

    func releaseInvocation() {
        invocationContinuation?.resume()
        invocationContinuation = nil
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    private func invoke() async -> AgentRuntimeResponse {
        invocationCount += 1
        if suspendInvocation {
            suspendInvocation = false
            await withCheckedContinuation { invocationContinuation = $0 }
        }
        return .success(.init(
            outcome: .completed,
            message: "done",
            questions: [],
            summary: "done",
            artifacts: [],
            retryDisposition: .none,
            errorCategory: nil,
            connectedCapability: nil
        ))
    }
}

@MainActor
final class AgentExecutionGateTests: XCTestCase {
    func test_tryAcquireAllowsOnlyOneOwnerUntilReleased() throws {
        let gate = AgentExecutionGate()

        let token = try XCTUnwrap(gate.tryAcquire(owner: "source sweep"))

        XCTAssertEqual(gate.owner, "source sweep")
        XCTAssertNil(gate.tryAcquire(owner: "delegated task"))
        gate.release(token)
        XCTAssertNil(gate.owner)
        XCTAssertNotNil(gate.tryAcquire(owner: "delegated task"))
    }

    func test_staleTokenCannotReleaseNewOwner() throws {
        let gate = AgentExecutionGate()
        let stale = try XCTUnwrap(gate.tryAcquire(owner: "first"))
        gate.release(stale)
        let current = try XCTUnwrap(gate.tryAcquire(owner: "second"))

        gate.release(stale)

        XCTAssertEqual(gate.owner, "second")
        XCTAssertNil(gate.tryAcquire(owner: "third"))
        gate.release(current)
        XCTAssertNil(gate.owner)
    }

    func test_serviceFailureReleasesGate_andCoordinatorCannotClaimWhileServiceRuns() async throws {
        let gate = AgentExecutionGate()
        let claude = GateClaudeProbe(
            result: ClaudeResult(ok: false, text: "provider failed"),
            suspend: true
        )
        let runtime = GateRuntimeProbe()
        let context = try makeContext()
        let service = AgentService(
            context: context,
            claude: { await claude.run($0, $1) },
            executionGate: gate
        )
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            executionGate: gate,
            persist: { try context.save() },
            contractProvider: { "Return structured output." }
        )
        let task = insertRoutedTask(in: context)

        let sweep = Task { await service.sweep(vaultPath: "/kb/DL") }
        await waitUntil { await claude.invocationCount == 1 }

        await coordinator.runNext(settings: settings)

        let blockedRuntimeCount = await runtime.invocationCount
        XCTAssertEqual(blockedRuntimeCount, 0)
        XCTAssertEqual(task.stage, .forAgent)
        XCTAssertEqual(gate.owner, "source sweep")
        await claude.release()
        await sweep.value
        XCTAssertNil(gate.owner)

        await coordinator.runNext(settings: settings)
        let releasedRuntimeCount = await runtime.invocationCount
        XCTAssertEqual(releasedRuntimeCount, 1)
        XCTAssertEqual(task.stage, .needsReview)
    }

    func test_coordinatorHoldsGateThroughCancellationDrain_thenServiceCanRun() async throws {
        let gate = AgentExecutionGate()
        let runtime = GateRuntimeProbe(suspendInvocation: true, suspendCancellation: true)
        let claude = GateClaudeProbe(result: ClaudeResult(ok: false, text: "provider failed"))
        let context = try makeContext()
        let service = AgentService(
            context: context,
            claude: { await claude.run($0, $1) },
            executionGate: gate
        )
        let coordinator = AgentTaskCoordinator(
            context: context,
            runtime: runtime,
            executionGate: gate,
            persist: { try context.save() },
            contractProvider: { "Return structured output." }
        )
        let task = insertRoutedTask(in: context)
        let turn = Task { await coordinator.runNext(settings: settings) }
        await waitUntil { await runtime.invocationCount == 1 }

        await service.sweep(vaultPath: "/kb/DL")
        let blockedClaudeCount = await claude.invocationCount
        XCTAssertEqual(blockedClaudeCount, 0)
        XCTAssertEqual(task.stage, .inProgress)

        coordinator.cancelActive()
        await waitUntil { await runtime.cancellationCount == 1 }
        await runtime.releaseInvocation()
        await Task.yield()
        await service.sweep(vaultPath: "/kb/DL")
        let cancellingClaudeCount = await claude.invocationCount
        XCTAssertEqual(cancellingClaudeCount, 0, "cancellation must drain before release")

        await runtime.releaseCancellation()
        await turn.value
        XCTAssertNil(gate.owner)

        await service.sweep(vaultPath: "/kb/DL")
        let releasedClaudeCount = await claude.invocationCount
        XCTAssertEqual(releasedClaudeCount, 1)
    }

    private var settings: SourceSettings {
        SourceSettings(sources: [
            SourceConfig(
                id: .vault,
                project: "DL-Knowledge-Base",
                enabled: true,
                workingDirectory: "/kb/DL"
            )
        ], state: [])
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func insertRoutedTask(in context: ModelContext) -> MustardTask {
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "Work", area: area)
        let task = MustardTask(title: "Delegated work", owner: .agent)
        task.stage = .forAgent
        task.list = list
        context.insert(area)
        context.insert(list)
        context.insert(task)
        return task
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
