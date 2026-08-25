import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class AgentServiceIngestExternalTests: XCTestCase {
    private func makeAgent() throws -> (AgentService, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        let context = ModelContext(container)
        let agent = AgentService(context: context, claude: { _, _ in
            ClaudeResult(ok: true, text: "[]")
        })
        return (agent, context)
    }

    private func proposal(event: String, item: String = "t1") -> SourceProposal {
        SourceProposal(source: .gmail, project: "DL-Knowledge-Base",
                       sourceItemID: item, sourceEventID: event,
                       title: "Reply to Ana", actionType: "draft_email",
                       confidence: 0.9, draft: "Hi Ana")
    }

    func testIngestExternalInsertsAndStampsProvenance() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([proposal(event: "m1")], vaultPath: "/kb/DL-Knowledge-Base")
        let recs = try context.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.source, "gmail")
        XCTAssertEqual(recs.first?.sourceEventID, "m1")
        XCTAssertEqual(recs.first?.vaultPath, "/kb/DL-Knowledge-Base")
    }

    func testIngestExternalDeduplicatesByEventID() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([proposal(event: "m1")], vaultPath: "/kb")
        // m2 carries a distinct thread (sourceItemID): SourceDedupe rule 2 rejects a
        // same-(source, item, action) proposal while the first rec is still pending.
        await agent.ingestExternal([proposal(event: "m1"), proposal(event: "m2", item: "t2")],
                                   vaultPath: "/kb")
        let recs = try context.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2)
    }

    func testIngestExternalRejectsPendingDuplicateOfSameThreadAndAction() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([proposal(event: "m1")], vaultPath: "/kb")
        // Same thread, same action, new message id, first rec still pending → rule 2 drops it.
        await agent.ingestExternal([proposal(event: "m2")], vaultPath: "/kb")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recommendation>()).count, 1)
    }

    func testIngestExternalEmptyIsANoOp() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([], vaultPath: "/kb")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }
}
