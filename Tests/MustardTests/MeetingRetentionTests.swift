import XCTest
import SwiftData
@testable import MustardKit

/// Retention and deletion (Meetings Task 10, BAK-302): the 30-day audio rule
/// (pinned exempt), exact validated cleanup, Trash-FIRST meeting deletion
/// where any failure preserves metadata and paths, and idempotent retries.
/// Pinned now/timezone; a temp Recordings root; the Trash is a stub.
@MainActor
final class MeetingRetentionTests: XCTestCase {

    private var root: URL!
    private var store: MeetingAudioStore!
    /// 2026-07-29T12:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_785_326_400)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-retention-\(UUID().uuidString)/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingAudioStore(recordingsRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
            MustardTask.self, Area.self, TaskList.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func meeting(
        in context: ModelContext,
        uid: String = "m1",
        endedDaysAgo: Double,
        pinned: Bool = false,
        withAudio: Bool = true
    ) -> MeetingRecord {
        let record = MeetingRecord(title: "Standup")
        record.uid = uid
        record.status = .ready
        record.endedAt = now.addingTimeInterval(-endedDaysAgo * 86_400)
        record.pinned = pinned
        if withAudio {
            record.youAudioPath = "Recordings/\(uid)/you.m4a"
        }
        context.insert(record)
        try? context.save()
        return record
    }

    private func materializeAudio(uid: String) throws {
        try store.createMeetingDirectory(forMeetingUID: uid)
        let url = try store.fileURL(for: .you, meetingUID: uid)
        try Data("audio".utf8).write(to: url)
    }

    // MARK: - The 30-day rule (pinned time, day edges)

    func test_audioAt29Days_isNotDue() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 29)
        XCTAssertTrue(MeetingRetention.audioDue([record], now: now).isEmpty)
    }

    func test_audioAtExactly30Days_isDue() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 30)
        XCTAssertEqual(MeetingRetention.audioDue([record], now: now).map(\.uid), ["m1"])
    }

    func test_audioAt31Days_isDue() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 31)
        XCTAssertEqual(MeetingRetention.audioDue([record], now: now).count, 1)
    }

    func test_pinnedMeetings_areExempt() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 90, pinned: true)
        XCTAssertTrue(MeetingRetention.audioDue([record], now: now).isEmpty)
    }

    func test_meetingsWithoutAudio_areNeverDue() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 90, withAudio: false)
        XCTAssertTrue(MeetingRetention.audioDue([record], now: now).isEmpty)
    }

    func test_explicitRetentionDeadline_overridesTheDefault() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 5)
        record.retentionDeadline = now.addingTimeInterval(-60)
        XCTAssertEqual(MeetingRetention.audioDue([record], now: now).count, 1)
    }

    // MARK: - Delete Audio (exact, validated, idempotent)

    func test_deleteAudio_removesTheDirectory_andClearsPaths() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 31)
        try materializeAudio(uid: "m1")

        try MeetingRetention.deleteAudio(for: record, store: store, context: context)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try store.directoryURL(forMeetingUID: "m1").path))
        XCTAssertNil(record.youAudioPath)
        XCTAssertEqual(record.status, .ready, "transcript and metadata stay reviewable")
        XCTAssertEqual(record.title, "Standup")
    }

    func test_deleteAudio_withAlreadyMissingFiles_stillSucceeds() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 31)
        // No directory was ever created.

        try MeetingRetention.deleteAudio(for: record, store: store, context: context)

        XCTAssertNil(record.youAudioPath)
    }

    func test_deleteAudio_refusesATraversalUID_untouched() throws {
        let context = try ctx()
        let record = meeting(in: context, uid: "../escape", endedDaysAgo: 31)

        XCTAssertThrowsError(
            try MeetingRetention.deleteAudio(for: record, store: store, context: context))
        XCTAssertNotNil(record.youAudioPath, "a refused delete changes nothing")
    }

    // MARK: - Delete Meeting (Trash FIRST, then SwiftData)

    func test_deleteMeeting_trashesTheExactDirectory_thenDeletesTheRecord() throws {
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 1)
        try materializeAudio(uid: "m1")
        var trashed: URL?

        try MeetingRetention.deleteMeeting(
            record, store: store, context: context,
            trash: { url in
                trashed = url
                try FileManager.default.removeItem(at: url)
            })

        XCTAssertEqual(trashed?.lastPathComponent, "m1", "the exact validated directory goes to Trash")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingRecord>()).count, 0)
    }

    func test_trashFailure_keepsMetadataAndPaths_andIsRetryable() throws {
        struct TrashBroken: Error {}
        let context = try ctx()
        let record = meeting(in: context, endedDaysAgo: 1)
        try materializeAudio(uid: "m1")

        XCTAssertThrowsError(
            try MeetingRetention.deleteMeeting(
                record, store: store, context: context,
                trash: { _ in throw TrashBroken() }))

        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingRecord>()).count, 1)
        XCTAssertEqual(record.youAudioPath, "Recordings/m1/you.m4a", "failure keeps everything")

        // The retry with a working Trash succeeds.
        try MeetingRetention.deleteMeeting(
            record, store: store, context: context,
            trash: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingRecord>()).count, 0)
    }
}
