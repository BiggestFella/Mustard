import XCTest
@testable import MustardKit

final class TaskStageTests: XCTestCase {
    func test_allViews_includeInboxAndDone() {
        for view in BoardOwnerView.allCases {
            XCTAssertTrue(view.columns.contains(.inbox), "\(view) missing inbox")
            XCTAssertTrue(view.columns.contains(.done), "\(view) missing done")
        }
    }

    func test_mineView_excludesAgentOnlyStages() {
        // In Progress is intentionally shared by Mine and Agent; these stages are agent-only.
        let agentOnlyStages: Set<TaskStage> = [.forAgent, .needsApproval, .queued, .needsInput, .needsReview]
        XCTAssertTrue(BoardOwnerView.mine.columns.allSatisfy { !agentOnlyStages.contains($0) })
    }

    func test_mineView_preservesExactColumnsInOrder() {
        XCTAssertEqual(BoardOwnerView.mine.columns,
                       [.inbox, .planned, .scheduled, .inProgress, .blocked, .done])
    }

    func test_everyoneView_isTheFullPipelineInOrder() {
        XCTAssertEqual(BoardOwnerView.everyone.columns,
            [.inbox, .planned, .scheduled, .forAgent, .needsApproval,
             .queued, .inProgress, .needsInput, .needsReview, .blocked, .done])
    }

    func test_agentView_columns() {
        XCTAssertEqual(BoardOwnerView.agent.columns,
            [.inbox, .forAgent, .needsApproval, .queued, .inProgress,
             .needsInput, .needsReview, .done])
    }

    func test_needsInput_isHumanGate() {
        XCTAssertEqual(TaskStage.needsInput.label, "Needs You")
        XCTAssertEqual(TaskStage.needsInput.subLabel, "answer the agent")
        XCTAssertEqual(TaskStage.needsInput.kind, .gate)
    }

    func test_kind_perStage() {
        XCTAssertEqual(TaskStage.forAgent.kind, .handoff)
        XCTAssertEqual(TaskStage.needsApproval.kind, .gate)
        XCTAssertEqual(TaskStage.queued.kind, .agent)
        XCTAssertEqual(TaskStage.needsInput.kind, .gate)
        XCTAssertEqual(TaskStage.needsReview.kind, .gate)
        XCTAssertEqual(TaskStage.blocked.kind, .warn)
        XCTAssertEqual(TaskStage.done.kind, .done)
        XCTAssertEqual(TaskStage.planned.kind, .standard)
    }
}
