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

    func test_approveTarget_needsApproval_unknownActionType_toQueued() {
        let t = MustardTask(title: "Mystery outward thing")
        t.stage = .needsApproval
        t.actionTypeRaw = "draft_emial"
        XCTAssertTrue(t.isGated)
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .queued)
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

    // MARK: Ledger meeting tasks — existence triage, not execution

    /// Keeping a ledger-harvested meeting task means "yes, this is really mine to
    /// do". It lands on your own board and nothing runs; delegation is separate.
    func test_approveTarget_ledgerMeetingTask_ownedByMe_toPlanned() {
        let t = MustardTask(title: "Move the Sales Buddi Miro board")
        t.source = MeetingTaskSource.ledger
        t.stage = .needsApproval
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .planned)
    }

    /// A gated action type must not drag a kept meeting task into the run lane —
    /// keeping is never executing, whatever the action says.
    func test_approveTarget_ledgerMeetingTask_gatedAction_stillPlanned() {
        let t = MustardTask(title: "Reply to Valeria")
        t.source = MeetingTaskSource.ledger
        t.stage = .needsApproval
        t.actionType = .draftEmail
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .planned)
    }

    /// After a hand-off the task is agent-owned again, and approving it at the gate
    /// legitimately means "run it" — the execute approval, not the existence one.
    func test_approveTarget_ledgerMeetingTask_agentOwned_toQueued() {
        let t = MustardTask(title: "Move the Sales Buddi Miro board", owner: .agent)
        t.source = MeetingTaskSource.ledger
        t.stage = .needsApproval
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .queued)
    }

    /// Recording-originated actions are approved for execution, not for existence.
    func test_approveTarget_recordingMeetingTask_unchanged() {
        let t = MustardTask(title: "Recording action item")
        t.source = MeetingTaskSource.recording
        t.stage = .needsApproval
        XCTAssertEqual(PersonalBoard.approveTarget(for: t), .needsReview)
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

    func test_moveToQueued_doesNotGrantRecordingApprovalBit() {
        let t = MustardTask(title: "From a recording", owner: .agent)
        t.source = "meeting-recording"
        t.stage = .needsApproval

        PersonalBoard.move(t, to: .queued)
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
