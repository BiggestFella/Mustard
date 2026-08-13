import Foundation
import SwiftData
import XCTest
@testable import MustardKit

@MainActor
final class CodeHeroesDecisionActionServiceTests: XCTestCase {
    func test_approveMarksProjectionDoneAfterAdapterCompletes() async throws {
        let context = try makeContext()
        let task = insertProjection(in: context)
        let runner = StubRunner(result: .init(
            requestID: "RESP-1", status: "completed", message: "Decision approved and applied",
            clusterID: "DL-01", decisionIDs: ["DEC-20260814-0001"], mustardRunID: "run-1"
        ))
        let service = AgentService(context: context, codeHeroesActionRunner: runner)

        await service.approveCodeHeroes(task)

        XCTAssertEqual(task.stage, .done)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertFalse(service.isExecuting)
        XCTAssertNil(service.lastError)
    }

    func test_ignoreMarksProjectionDoneAndRecordsAuditableLocalTag() async throws {
        let context = try makeContext()
        let task = insertProjection(in: context)
        let runner = StubRunner(result: .init(
            requestID: "RESP-2", status: "ignored", message: "Decision ignored",
            clusterID: "DL-01", decisionIDs: ["DEC-20260814-0001"], mustardRunID: "run-2"
        ))
        let service = AgentService(context: context, codeHeroesActionRunner: runner)

        await service.ignoreCodeHeroes(task)

        XCTAssertEqual(task.stage, .done)
        XCTAssertTrue(task.tags.contains("response:ignored"))
    }

    func test_commentLeavesProjectionInNeedsInputAndPreservesReason() async throws {
        let context = try makeContext()
        let task = insertProjection(in: context)
        let runner = StubRunner(result: .init(
            requestID: "RESP-3", status: "commented", message: "Comment recorded",
            clusterID: "DL-01", decisionIDs: ["DEC-20260814-0001"], mustardRunID: "run-3"
        ))
        let service = AgentService(context: context, codeHeroesActionRunner: runner)

        await service.commentCodeHeroes(task, text: "Please keep the existing rollout boundary.")

        XCTAssertEqual(task.stage, .needsInput)
        XCTAssertTrue(task.tags.contains("response:commented"))
        XCTAssertTrue(task.notes.contains("Comment sent"))
    }

    func test_conflictMovesProjectionToReviewAndSurfacesAdapterMessage() async throws {
        let context = try makeContext()
        let task = insertProjection(in: context)
        let runner = StubRunner(result: .init(
            requestID: "RESP-4", status: "conflict", message: "Queue changed; refresh before responding.",
            clusterID: "DL-01", decisionIDs: ["DEC-20260814-0001"], mustardRunID: "run-4"
        ))
        let service = AgentService(context: context, codeHeroesActionRunner: runner)

        await service.approveCodeHeroes(task)

        XCTAssertEqual(task.stage, .needsReview)
        XCTAssertTrue(task.tags.contains("response:blocked"))
        XCTAssertEqual(service.lastError, "Queue changed; refresh before responding.")
    }

    func test_feedbackCandidateAppearsOnlyAfterThreeDistinctRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("operations/decisions/triage", isDirectory: true),
            withIntermediateDirectories: true
        )
        let context = try makeContext()
        let service = AgentService(context: context)
        let now = Date(timeIntervalSince1970: 1_756_000_000)

        for index in 1...3 {
            let task = insertProjection(in: context, root: root, cluster: "DL-\(index)")
            let result = service.recordCodeHeroesFeedback(
                task, signal: .tooNoisy, now: now.addingTimeInterval(TimeInterval(index))
            )
            XCTAssertNotNil(result)
            if index < 3 { XCTAssertTrue(result?.candidates.isEmpty == true) }
        }

        let candidates = try context.fetch(FetchDescriptor<MustardTask>()).filter {
            $0.source == "codeheroes:feedback-candidate"
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].stage, .needsReview)
        XCTAssertTrue(candidates[0].tags.contains("human-action"))
    }

    private func insertProjection(
        in context: ModelContext,
        root: URL = URL(fileURLWithPath: "/tmp/code-heroes"),
        cluster: String = "DL-01"
    ) -> MustardTask {
        let task = MustardTask(title: "Resolve Code Heroes decision", owner: .agent)
        task.source = CodeHeroesDecisionPolicy.source
        task.stage = .needsInput
        task.sourceURL = root.appendingPathComponent("operations/decisions/triage/queue.json").path
        task.sourceContext = "digest=sha256:\(String(repeating: "a", count: 64));cluster=\(cluster);source_ids=DEC-20260814-0001;decision_digests=DEC-20260814-0001:sha256:\(String(repeating: "b", count: 64))"
        task.tags = ["codeheroes", "decision", "project:dl", "human-action"]
        context.insert(task)
        try? context.save()
        return task
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

private struct StubRunner: CodeHeroesDecisionActionRunning {
    let result: CodeHeroesDecisionActionResult

    func run(
        request: CodeHeroesDecisionActionRequest,
        settings: CodeHeroesQueueSettings
    ) async -> CodeHeroesDecisionActionResult {
        result
    }
}
