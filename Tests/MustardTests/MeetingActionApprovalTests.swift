import XCTest
import SwiftData
@testable import MustardKit

/// Approval-gated proposal → task conversion (Meetings Task 8, BAK-300):
/// exactly one linked Inbox task per approval, idempotent re-approval,
/// rejection creates nothing, evidence survives, reviewed edits apply, and
/// nothing outward ever runs.
@MainActor
final class MeetingActionApprovalTests: XCTestCase {

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
            MustardTask.self, Area.self, TaskList.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func proposal(in context: ModelContext) -> MeetingActionProposal {
        let meeting = MeetingRecord(title: "Standup")
        context.insert(meeting)
        let proposal = MeetingActionProposal(
            title: "Ship the release",
            notes: "Discussed at length",
            supportingSegmentUIDs: ["microphone:seg-1", "meeting:seg-2"])
        proposal.meeting = meeting
        context.insert(proposal)
        try? context.save()
        return proposal
    }

    private func tasks(in context: ModelContext) throws -> [MustardTask] {
        try context.fetch(FetchDescriptor<MustardTask>())
    }

    // MARK: - Approve

    func test_approve_createsExactlyOneLinkedInboxTask() throws {
        let context = try ctx()
        let proposal = proposal(in: context)

        let task = MeetingActionApproval.approve(proposal, context: context)

        XCTAssertEqual(try tasks(in: context).count, 1)
        XCTAssertEqual(task.title, "Ship the release")
        XCTAssertEqual(task.status, .inbox)
        XCTAssertEqual(task.source, "meeting-recording")
        XCTAssertEqual(task.sourceContext, "Standup")
        XCTAssertEqual(task.originKey, proposal.uid, "the proposal uid anchors idempotency")
        XCTAssertIdentical(proposal.createdTask, task)
        XCTAssertEqual(proposal.state, .approved)
        XCTAssertEqual(task.owner, .me, "approval never hands work to the agent (no outward action)")
    }

    func test_secondApproval_isIdempotent() throws {
        let context = try ctx()
        let proposal = proposal(in: context)

        let first = MeetingActionApproval.approve(proposal, context: context)
        let second = MeetingActionApproval.approve(proposal, context: context)

        XCTAssertIdentical(first, second)
        XCTAssertEqual(try tasks(in: context).count, 1)
    }

    // MARK: - Reject

    func test_reject_createsNoTask() throws {
        let context = try ctx()
        let proposal = proposal(in: context)

        MeetingActionApproval.reject(proposal, context: context)

        XCTAssertEqual(try tasks(in: context).count, 0)
        XCTAssertEqual(proposal.state, .rejected)
        XCTAssertNil(proposal.createdTask)
    }

    // MARK: - Evidence & edits

    func test_evidence_survivesApproval() throws {
        let context = try ctx()
        let proposal = proposal(in: context)

        _ = MeetingActionApproval.approve(proposal, context: context)

        XCTAssertEqual(
            proposal.supportingSegmentUIDs, ["microphone:seg-1", "meeting:seg-2"],
            "the transcript evidence stays on the proposal after approval")
    }

    func test_reviewedEdits_applyToTheCreatedTask() throws {
        let context = try ctx()
        context.insert(Area(name: "Code Heroes"))
        let proposal = proposal(in: context)
        let due = ISO8601DateFormatter().date(from: "2026-07-31T09:00:00Z")!

        let task = MeetingActionApproval.approve(
            proposal,
            title: "Ship v2 on Friday",
            scheduledFor: due,
            areaName: "Code Heroes",
            context: context)

        XCTAssertEqual(task.title, "Ship v2 on Friday")
        XCTAssertEqual(task.scheduledAt, due)
        XCTAssertEqual(task.list?.area?.name, "Code Heroes")
    }
}
