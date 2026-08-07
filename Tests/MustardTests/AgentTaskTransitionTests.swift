import XCTest
@testable import MustardKit

final class AgentTaskTransitionTests: XCTestCase {
    func test_decisionMapsCompleteOutcomeMatrix() {
        let expected: [(AgentTurnOutcome, AgentTransitionDecision)] = [
            (
                .needsInput,
                AgentTransitionDecision(
                    taskStage: .needsInput,
                    runState: .needsInput,
                    releasesSlot: true
                )
            ),
            (
                .completed,
                AgentTransitionDecision(
                    taskStage: .needsReview,
                    runState: .completed,
                    releasesSlot: true
                )
            ),
            (
                .requiresConnectedWorker,
                AgentTransitionDecision(
                    taskStage: .queued,
                    runState: .queued,
                    releasesSlot: true,
                    requiresConnectedWorker: true
                )
            ),
            (
                .failed,
                AgentTransitionDecision(
                    taskStage: .queued,
                    runState: .failed,
                    releasesSlot: true
                )
            ),
            (
                .cancelled,
                AgentTransitionDecision(
                    taskStage: .planned,
                    runState: .cancelled,
                    releasesSlot: true,
                    taskOwner: .me
                )
            ),
        ]

        for (outcome, decision) in expected {
            XCTAssertEqual(AgentTaskTransition.decision(for: outcome), decision)
        }
    }

    func test_cancelledDecisionPlacesAppliedTaskInMinePlannedColumn() {
        let task = MustardTask(title: "Cancelled work", owner: .agent)
        task.stage = .inProgress
        let decision = AgentTaskTransition.decision(for: .cancelled)

        task.stage = decision.taskStage
        if let taskOwner = decision.taskOwner {
            task.owner = taskOwner
        }

        XCTAssertEqual(PersonalBoard.tasks([task], in: .planned, view: .mine, area: .all), [task])
        XCTAssertTrue(PersonalBoard.tasks([task], in: .planned, view: .agent, area: .all).isEmpty)
    }
}
