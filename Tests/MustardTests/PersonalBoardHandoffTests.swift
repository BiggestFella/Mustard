import XCTest
@testable import MustardKit

/// BAK-90: a task can only be handed off to the agent once it has a client area —
/// the bridge export filters by area, so an area-less hand-off would silently never
/// route. `canHandOffToAgent` is the pure gate the views + AgentService.delegate check.
final class PersonalBoardHandoffTests: XCTestCase {
    func test_canHandOff_falseWhenNoList() {
        XCTAssertFalse(PersonalBoard.canHandOffToAgent(MustardTask(title: "x")))
    }

    func test_canHandOff_falseWhenListHasNoArea() {
        let t = MustardTask(title: "x")
        t.list = TaskList(name: "loose")   // area-less list
        XCTAssertFalse(PersonalBoard.canHandOffToAgent(t))
    }

    func test_canHandOff_trueWithArea() {
        let t = MustardTask(title: "x")
        t.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        XCTAssertTrue(PersonalBoard.canHandOffToAgent(t))
    }

    // MARK: - Agent-lane source of truth

    func test_isAgentLane_coversTheSixHandOffStages() {
        for s in [TaskStage.forAgent, .needsApproval, .queued, .inProgress, .needsInput, .needsReview] {
            XCTAssertTrue(PersonalBoard.isAgentLane(s), "\(s) should be an agent lane")
        }
        for s in [TaskStage.inbox, .planned, .scheduled, .blocked, .done] {
            XCTAssertFalse(PersonalBoard.isAgentLane(s), "\(s) should not be an agent lane")
        }
    }

    // MARK: - newTaskPlacement (BAK: quick-add can't strand an area-less card in an agent lane)

    func test_placement_nonAgentColumn_isMeOwnedNoAreaNoBlock() {
        let p = PersonalBoard.newTaskPlacement(inColumn: .planned, boardArea: .all)
        XCTAssertEqual(p, .init(stage: .planned, owner: .me, attachArea: false, blockedHandOff: false))
    }

    func test_placement_inboxColumn_unaffected() {
        let p = PersonalBoard.newTaskPlacement(inColumn: .inbox, boardArea: .area("Digital Licence"))
        XCTAssertEqual(p, .init(stage: .inbox, owner: .me, attachArea: false, blockedHandOff: false))
    }

    func test_placement_agentLane_withScopedArea_handsOff() {
        let p = PersonalBoard.newTaskPlacement(inColumn: .forAgent, boardArea: .area("Digital Licence"))
        XCTAssertEqual(p, .init(stage: .forAgent, owner: .agent, attachArea: true, blockedHandOff: false))
    }

    func test_placement_agentLane_allAreas_downgradesToPlannedAndBlocks() {
        let p = PersonalBoard.newTaskPlacement(inColumn: .forAgent, boardArea: .all)
        XCTAssertEqual(p, .init(stage: .planned, owner: .me, attachArea: false, blockedHandOff: true))
    }

    func test_placement_agentLane_personalArea_downgrades() {
        let p = PersonalBoard.newTaskPlacement(inColumn: .queued, boardArea: .personal)
        XCTAssertEqual(p, .init(stage: .planned, owner: .me, attachArea: false, blockedHandOff: true))
    }
}
