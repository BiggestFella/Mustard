import XCTest
import SwiftData
@testable import MustardKit

/// The meeting recorder's CloudKit-shaped data model (Meetings Task 1,
/// BAK-293): defaults, relationships, enum round-trips, and the
/// relative-audio-path rule. Store-backed assertions use an in-memory
/// container that includes the new models.
@MainActor
final class MeetingRecordModelTests: XCTestCase {

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
            MustardTask.self, Area.self, TaskList.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    // MARK: - Defaults

    func test_freshRecord_defaultsToPreparing_withNothingElseSet() throws {
        let context = try ctx()
        let record = MeetingRecord(title: "Standup")
        context.insert(record)
        try context.save()

        XCTAssertEqual(record.status, .preparing)
        XCTAssertEqual(record.digestStatus, .pending)
        XCTAssertFalse(record.pinned)
        XCTAssertFalse(record.audioFinalized)
        XCTAssertNil(record.youAudioPath)
        XCTAssertNil(record.meetingAudioPath)
        XCTAssertNil(record.playbackAudioPath)
        XCTAssertNil(record.retentionDeadline)
        XCTAssertNil(record.errorMessage)
        XCTAssertFalse(record.uid.isEmpty, "a stable UID exists from birth")
    }

    func test_freshProposal_defaultsToPending_withNoTask() {
        let proposal = MeetingActionProposal(title: "Send the deck")
        XCTAssertEqual(proposal.state, .pending)
        XCTAssertNil(proposal.createdTask)
        XCTAssertNil(proposal.scheduledFor)
        XCTAssertTrue(proposal.supportingSegmentUIDs.isEmpty)
    }

    // MARK: - Relationships

    func test_optionalRelationships_decodeAsNilAndEmpty() throws {
        let context = try ctx()
        let record = MeetingRecord(title: "Standup")
        context.insert(record)
        try context.save()

        let fetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<MeetingRecord>()).first)
        XCTAssertNil(fetched.calendarEvent)
        XCTAssertEqual(fetched.segments?.count ?? 0, 0)
        XCTAssertEqual(fetched.proposals?.count ?? 0, 0)
    }

    func test_deletingARecord_cascadesSegmentsAndProposals_butNeverTasks() throws {
        let context = try ctx()
        let record = MeetingRecord(title: "Standup")
        context.insert(record)
        let segment = MeetingTranscriptSegment(rawText: "we should ship on Friday")
        segment.meeting = record
        context.insert(segment)
        let proposal = MeetingActionProposal(title: "Ship on Friday")
        proposal.meeting = record
        let task = MustardTask(title: "Ship on Friday")
        context.insert(task)
        proposal.createdTask = task
        context.insert(proposal)
        try context.save()

        context.delete(record)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingTranscriptSegment>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingActionProposal>()).count, 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MustardTask>()).count, 1,
            "an approved task outlives its meeting (nullify, never cascade)")
    }

    func test_proposalApproval_linksExactlyOneTask() throws {
        let context = try ctx()
        let proposal = MeetingActionProposal(title: "Ship on Friday")
        context.insert(proposal)
        let task = MustardTask(title: "Ship on Friday")
        context.insert(task)

        proposal.state = .approved
        proposal.createdTask = task
        try context.save()

        XCTAssertEqual(proposal.state, .approved)
        XCTAssertIdentical(proposal.createdTask, task)
    }

    // MARK: - Enum round-trips

    func test_segmentSource_roundTripsThroughRawStorage() {
        let segment = MeetingTranscriptSegment(rawText: "hello")
        XCTAssertEqual(segment.source, .you, "microphone is the default channel")
        segment.source = .meeting
        XCTAssertEqual(segment.sourceRaw, "meeting")
        XCTAssertEqual(segment.source, .meeting)
        segment.source = .you
        XCTAssertEqual(segment.sourceRaw, "you")
    }

    func test_recordStatus_roundTripsThroughRawStorage() {
        let record = MeetingRecord(title: "Standup")
        record.status = .recording
        XCTAssertEqual(record.statusRaw, "recording")
        record.status = .partial
        XCTAssertEqual(record.status, .partial)
    }

    func test_proposalState_roundTripsThroughRawStorage() {
        let proposal = MeetingActionProposal(title: "x")
        proposal.state = .rejected
        XCTAssertEqual(proposal.stateRaw, "rejected")
        XCTAssertEqual(proposal.state, .rejected)
    }

    // MARK: - Relative audio paths (spec §Files: relative, validated, never absolute)

    func test_audioPaths_acceptOnlyRelativePaths() {
        XCTAssertEqual(
            MeetingRecord.validatedRelativeAudioPath("Recordings/abc/you.m4a"),
            "Recordings/abc/you.m4a")
        XCTAssertNil(MeetingRecord.validatedRelativeAudioPath("/tmp/evil.m4a"))
        XCTAssertNil(MeetingRecord.validatedRelativeAudioPath("~/Music/evil.m4a"))
        XCTAssertNil(MeetingRecord.validatedRelativeAudioPath("Recordings/../../etc/passwd"))
        XCTAssertNil(MeetingRecord.validatedRelativeAudioPath(""))
    }

    // MARK: - Evidence separation

    func test_correctedText_neverReplacesRawText() {
        let segment = MeetingTranscriptSegment(rawText: "we should ship on friday")
        segment.correctedText = "We should ship on Friday."
        XCTAssertEqual(segment.rawText, "we should ship on friday", "raw transcript is immutable evidence")
        XCTAssertEqual(segment.correctedText, "We should ship on Friday.")
    }
}
