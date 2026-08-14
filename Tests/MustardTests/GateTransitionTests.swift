import XCTest
@testable import MustardKit

/// The gate-approval state machine (BAK-100). Approving a gate advances:
/// needsApproval → queued (gated; will run) or needsReview (non-gated; straight to
/// output review); needsReview → done. Reverse transitions (Hold / Request changes)
/// are plain `move(_:to:)` and need no dedicated mapping.
final class GateTransitionTests: XCTestCase {
    func test_approveTarget_needsApproval_gated_toQueued() {
        let t = MustardTask(title: "Send invoice chase")
        t.stage = .needsApproval
        t.actionType = .draftEmail // gated
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .queued)
    }

    func test_approveTarget_needsApproval_nonGated_toNeedsReview() {
        let t = MustardTask(title: "Update the vault")
        t.stage = .needsApproval
        t.actionType = .vaultNote // non-gated
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .needsReview)
    }

    func test_approveTarget_needsApproval_noActionType_toNeedsReview() {
        let t = MustardTask(title: "Bare task")
        t.stage = .needsApproval // no actionType → not gated
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .needsReview)
    }

    func test_approveTarget_agentOwnedWithoutActionType_toQueued() {
        let t = MustardTask(title: "Meeting task", owner: .agent)
        t.stage = .needsApproval

        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .queued)
    }

    func test_moveToQueued_grantsMeetingApproval_andHoldingClearsIt() {
        let t = MustardTask(title: "Meeting task", owner: .agent)
        t.source = "meeting"
        t.stage = .needsApproval

        PersonalBoard.move(t, to: .queued)
        XCTAssertTrue(t.agentApprovalGranted)

        PersonalBoard.move(t, to: .needsApproval)
        XCTAssertFalse(t.agentApprovalGranted)
    }

    func test_approveTarget_needsReview_toDone() {
        let t = MustardTask(title: "Review me")
        t.stage = .needsReview
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .done)
    }

    func test_approveTarget_nonGateStage_isNil() {
        let t = MustardTask(title: "Planned")
        t.stage = .planned
        XCTAssertNil(PersonalBoard.approveTarget(for: t))
    }
}
