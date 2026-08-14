import Foundation
import XCTest
@testable import MustardKit

final class CodeHeroesDecisionActionTests: XCTestCase {
    func test_builderUsesProjectionContextAndRecommendedOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = root.appendingPathComponent("operations/decisions/triage/queue.json")
        let decision = root.appendingPathComponent("operations/decisions/open/DEC-20260814-0001.md")
        try FileManager.default.createDirectory(at: decision.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("decision fixture".utf8).write(to: decision)
        let task = MustardTask(title: "Resolve the decision")
        task.source = CodeHeroesDecisionPolicy.source
        task.sourceURL = queue.path
        task.sourceContext = "digest=sha256:\(String(repeating: "a", count: 64));run=RUN-1;generated_at=2026-08-14T00:00:00Z;cluster=DL-01;source_ids=DEC-20260814-0001"
        task.links = [TaskLink(label: "Decision", url: decision.path)]

        let request = try CodeHeroesDecisionActionRequestBuilder.make(
            task: task,
            action: .approveAndRun,
            now: Date(timeIntervalSince1970: 1_755_129_600),
            runID: "run-1"
        )

        XCTAssertEqual(request.action, .approveAndRun)
        XCTAssertEqual(request.clusterID, "DL-01")
        XCTAssertEqual(request.decisionIDs, ["DEC-20260814-0001"])
        XCTAssertEqual(request.selectedOptions, ["DEC-20260814-0001": "__recommended__"])
        XCTAssertTrue(request.decisionDigests["DEC-20260814-0001"]?.hasPrefix("sha256:") == true)
        XCTAssertEqual(
            try CodeHeroesDecisionActionRequestBuilder.settings(for: task).repositoryRoot,
            root.path
        )
    }

    func test_commentRequiresShortNonEmptyText() throws {
        let task = projection()

        XCTAssertThrowsError(try CodeHeroesDecisionActionRequestBuilder.make(task: task, action: .comment, comment: "  ")) { error in
            XCTAssertEqual(error as? CodeHeroesDecisionActionError, .invalidComment)
        }
    }

    func test_nonProjectionCannotCreateCodeHeroesRequest() {
        let task = MustardTask(title: "ordinary")
        XCTAssertThrowsError(try CodeHeroesDecisionActionRequestBuilder.make(task: task, action: .ignore))
    }

    func test_resultRoundTripsFromAdapterJSONShape() throws {
        let result = CodeHeroesDecisionActionResult(
            requestID: "RESP-20260814-0001",
            status: "completed",
            message: "Decision approved and applied",
            clusterID: "DL-01",
            decisionIDs: ["DEC-20260814-0001"],
            mustardRunID: "run-1"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CodeHeroesDecisionActionResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.isSuccess)
        XCTAssertFalse(decoded.isBlocked)
    }

    private func projection() -> MustardTask {
        let task = MustardTask(title: "Resolve the decision")
        task.source = CodeHeroesDecisionPolicy.source
        task.sourceURL = "/tmp/repo/operations/decisions/triage/queue.json"
        task.sourceContext = "digest=sha256:\(String(repeating: "a", count: 64));cluster=DL-01;source_ids=DEC-20260814-0001"
        task.links = [TaskLink(label: "Decision", url: "/tmp/repo/operations/decisions/open/DEC-20260814-0001.md")]
        return task
    }
}
