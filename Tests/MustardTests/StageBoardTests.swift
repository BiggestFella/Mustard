import XCTest
@testable import MustardKit

/// Stage-based board logic (BAK-76). The legacy status-based tests live in
/// PersonalBoardTests until the BoardView rebuild removes that API.
final class StageBoardTests: XCTestCase {
    private func task(_ stage: TaskStage, owner: TaskOwner = .me, area: String? = nil) -> MustardTask {
        let t = MustardTask(title: "t"); t.stage = stage; t.owner = owner
        if let area {
            let a = Area(name: area, colorHex: "#000")
            let l = TaskList(name: "l"); l.area = a; t.list = l
        }
        return t
    }

    func test_columnsForView_matchOwnerView() {
        XCTAssertEqual(PersonalBoard.columns(for: .mine), BoardOwnerView.mine.columns)
        XCTAssertEqual(PersonalBoard.columns(for: .agent), BoardOwnerView.agent.columns)
    }

    func test_bucket_filtersByStage() {
        let all = [task(.inbox), task(.queued, owner: .agent), task(.inbox)]
        XCTAssertEqual(PersonalBoard.tasks(all, in: .inbox, view: .everyone, area: .all).count, 2)
        XCTAssertEqual(PersonalBoard.tasks(all, in: .queued, view: .everyone, area: .all).count, 1)
    }

    func test_mineView_excludesAgentOwned() {
        let all = [task(.inbox, owner: .me), task(.inbox, owner: .agent)]
        XCTAssertEqual(PersonalBoard.tasks(all, in: .inbox, view: .mine, area: .all).count, 1)
    }

    func test_agentView_excludesMeOwned() {
        let all = [task(.inbox, owner: .me), task(.inbox, owner: .agent)]
        XCTAssertEqual(PersonalBoard.tasks(all, in: .inbox, view: .agent, area: .all).count, 1)
    }

    func test_areaFilter_personalIsErrandsOrReading() {
        let all = [task(.inbox, area: "Errands"), task(.inbox, area: "DLA SDK")]
        XCTAssertEqual(PersonalBoard.tasks(all, in: .inbox, view: .everyone, area: .personal).count, 1)
        XCTAssertEqual(PersonalBoard.tasks(all, in: .inbox, view: .everyone, area: .area("DLA SDK")).count, 1)
    }

    func test_waitingCount_countsAllHumanAttentionStages_inScope() {
        let questionAndReview = [task(.needsInput, owner: .agent), task(.needsReview, owner: .agent)]
        XCTAssertEqual(PersonalBoard.waitingCount(questionAndReview, view: .everyone, area: .all), 2)

        let approval = task(.needsApproval, owner: .agent)
        XCTAssertEqual(PersonalBoard.waitingCount([approval], view: .everyone, area: .all), 1)
    }

    func test_waitingCount_respectsOwnerAndAreaScope() {
        let all = [
            task(.needsApproval, owner: .agent, area: "DLA SDK"),
            task(.needsInput, owner: .agent, area: "DLA SDK"),
            task(.needsReview, owner: .me, area: "DLA SDK"),
            task(.needsInput, owner: .agent, area: "Other"),
            task(.inbox, owner: .agent, area: "DLA SDK"),
        ]

        XCTAssertEqual(PersonalBoard.waitingCount(all, view: .everyone, area: .all), 4)
        XCTAssertEqual(PersonalBoard.waitingCount(all, view: .agent, area: .all), 3)
        XCTAssertEqual(PersonalBoard.waitingCount(all, view: .mine, area: .all), 1)
        XCTAssertEqual(PersonalBoard.waitingCount(all, view: .everyone, area: .area("DLA SDK")), 3)
        XCTAssertEqual(PersonalBoard.waitingCount(all, view: .agent, area: .area("DLA SDK")), 2)
    }

    func test_reassign_toAgentGoesForAgent_toMeGoesPlanned() {
        let t = task(.inbox)
        PersonalBoard.reassign(t, to: .agent)
        XCTAssertEqual(t.owner, .agent); XCTAssertEqual(t.stage, .forAgent)
        PersonalBoard.reassign(t, to: .me)
        XCTAssertEqual(t.owner, .me); XCTAssertEqual(t.stage, .planned)
    }

    func test_moveByStage_setsStage_andDoneStamps() {
        let t = task(.inbox)
        PersonalBoard.move(t, to: .queued)
        XCTAssertEqual(t.stage, .queued)
        PersonalBoard.move(t, to: .done)
        XCTAssertEqual(t.stage, .done); XCTAssertNotNil(t.completedAt)
    }

    func test_agentBadge_countsAllHumanAttentionStages_anyOwner() {
        let all = [task(.needsApproval, owner: .agent), task(.needsInput, owner: .agent),
                   task(.needsReview, owner: .me), task(.queued, owner: .agent)]
        XCTAssertEqual(PersonalBoard.agentBadge([all[1], all[2]]), 2)
        XCTAssertEqual(PersonalBoard.agentBadge(all), 3)
    }

    func test_agentLaneStages_includeFullAgentPipeline() {
        let expected: Set<TaskStage> = [.forAgent, .needsApproval, .queued, .inProgress,
                                        .needsInput, .needsReview]
        XCTAssertEqual(PersonalBoard.agentLaneStages, expected)
    }
}
