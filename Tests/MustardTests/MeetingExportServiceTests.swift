import XCTest
import SwiftData
@testable import MustardKit

/// Export (Meetings Task 10, BAK-302): Markdown with metadata, summary,
/// decisions, actions, and the timestamped transcript, plus the mixed audio —
/// into a user-chosen destination, never overwriting without confirmation.
@MainActor
final class MeetingExportServiceTests: XCTestCase {

    private var root: URL!
    private var destination: URL!
    private var store: MeetingAudioStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-export-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Recordings", isDirectory: true)
        destination = base.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
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

    private func meeting(in context: ModelContext) throws -> MeetingRecord {
        let record = MeetingRecord(title: "Release planning")
        record.uid = "m1"
        record.status = .ready
        record.startedAt = Date(timeIntervalSince1970: 1_785_326_400)
        record.summaryText = "We planned the v2 release."
        record.decisions = ["Ship Friday"]
        record.unresolvedQuestions = ["Who owns the changelog?"]
        let segment = MeetingTranscriptSegment(
            rawText: "let's ship it friday", source: .you, startSeconds: 65, endSeconds: 68)
        segment.meeting = record
        let proposal = MeetingActionProposal(title: "Ship the release")
        proposal.meeting = record
        context.insert(record)
        context.insert(segment)
        context.insert(proposal)
        record.playbackAudioPath = "Recordings/m1/playback.m4a"
        try store.createMeetingDirectory(forMeetingUID: "m1")
        try Data("audio".utf8).write(to: store.fileURL(for: .playback, meetingUID: "m1"))
        try context.save()
        return record
    }

    // MARK: - Markdown

    func test_markdown_carriesMetadataDigestActionsAndTimestampedTranscript() throws {
        let context = try ctx()
        let record = try meeting(in: context)

        let markdown = MeetingExportService.markdown(for: record)

        XCTAssertTrue(markdown.contains("# Release planning"))
        XCTAssertTrue(markdown.contains("We planned the v2 release."))
        XCTAssertTrue(markdown.contains("Ship Friday"))
        XCTAssertTrue(markdown.contains("Who owns the changelog?"))
        XCTAssertTrue(markdown.contains("Ship the release"))
        XCTAssertTrue(markdown.contains("[1:05]"), "transcript lines carry their timestamps")
        XCTAssertTrue(markdown.contains("let's ship it friday"))
    }

    // MARK: - Files

    func test_export_writesMarkdownAndAudio() throws {
        let context = try ctx()
        let record = try meeting(in: context)

        let written = try MeetingExportService.export(
            record, store: store, to: destination)

        XCTAssertEqual(written.count, 2)
        let names = Set(written.map(\.lastPathComponent))
        XCTAssertTrue(names.contains { $0.hasSuffix(".md") })
        XCTAssertTrue(names.contains { $0.hasSuffix(".m4a") })
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func test_export_neverOverwritesWithoutConfirmation() throws {
        let context = try ctx()
        let record = try meeting(in: context)
        _ = try MeetingExportService.export(record, store: store, to: destination)

        XCTAssertThrowsError(
            try MeetingExportService.export(record, store: store, to: destination)
        ) { error in
            guard case MeetingExportError.wouldOverwrite(let conflicts) = error else {
                return XCTFail("expected wouldOverwrite, got \(error)")
            }
            XCTAssertFalse(conflicts.isEmpty)
        }

        // Confirmed overwrite replaces in place.
        let rewritten = try MeetingExportService.export(
            record, store: store, to: destination, overwrite: true)
        XCTAssertEqual(rewritten.count, 2)
    }

    func test_export_withoutAudio_stillWritesTheMarkdown() throws {
        let context = try ctx()
        let record = try meeting(in: context)
        record.playbackAudioPath = nil
        record.youAudioPath = nil

        let written = try MeetingExportService.export(record, store: store, to: destination)

        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].lastPathComponent.hasSuffix(".md"))
    }
}
