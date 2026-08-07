import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class InboxIngestServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func writeRec(_ dir: URL, _ name: String, project: String, event: String, action: String = "draft_email") throws {
        let recs = dir.appendingPathComponent("_recs")
        try? FileManager.default.createDirectory(at: recs, withIntermediateDirectories: true)
        let json = """
        {"source":"gmail","project":"\(project)","sourceItemID":"thread-\(event)","sourceEventID":"\(event)",
         "sourceContext":"ctx","sourceURL":null,"occurredAt":null,"title":"t-\(event)","body":"b",
         "actionType":"\(action)","confidence":0.8,"reasoning":"r","draft":"d"}
        """
        try json.write(to: recs.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func test_ingestInbox_insertsGmailRecs_asPending_stampingProjectAndCwd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mustard-ing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRec(dir, "a.json", project: "DL", event: "msg-1")
        try writeRec(dir, "b.json", project: "DL", event: "msg-2")

        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "") })
        await service.ingestInbox(workingDirectory: dir.path)

        let recs = try ctx.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2)
        XCTAssertTrue(recs.allSatisfy { $0.source == "gmail" && $0.decision == .pending })
        XCTAssertTrue(recs.allSatisfy { $0.project == "DL" && $0.vaultPath == dir.path })
    }

    func test_ingestInbox_idempotentAcrossRuns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mustard-ing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRec(dir, "a.json", project: "DL", event: "msg-1")

        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "") })
        await service.ingestInbox(workingDirectory: dir.path)
        await service.ingestInbox(workingDirectory: dir.path)  // same files again

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 1,
                       "re-ingesting the same rec files must not duplicate")
    }
}
