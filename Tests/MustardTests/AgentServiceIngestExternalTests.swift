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
        // m2 carries a distinct thread (sourceItemID) so only rule 1 (event id) is in
        // play here; the same-thread pending rejection is pinned by the next test.
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

    func testIngestExternalCarriesOriginalSource() async throws {
        let (agent, context) = try makeAgent()
        let p = SourceProposal(
            source: .gmail, project: "DL-Knowledge-Base",
            sourceItemID: "t1", sourceEventID: "m1",
            sourceURL: "https://mail.google.com/mail/u/0/#all/m1",
            title: "Reply to Ana", actionType: "draft_email",
            originalSource: "please review the build",
            confidence: 0.9, draft: "Hi Ana")
        await agent.ingestExternal([p], vaultPath: "/kb")
        let rec = try context.fetch(FetchDescriptor<Recommendation>()).first
        XCTAssertEqual(rec?.originalSource, "please review the build")
        XCTAssertEqual(rec?.source, "gmail")
    }

    func testIngestExternalPreservesOriginalSourceAfterReclassify() async throws {
        let (agent, context) = try makeAgent()
        let p = SourceProposal(
            source: .gmail, project: "DL-Knowledge-Base",
            sourceItemID: "t1", sourceEventID: "m1",
            sourceContext: "Jira · DLA-1 · comment added",
            sourceURL: "https://mail.google.com/mail/u/0/#all/m1",
            title: "Reply to comment", actionType: "create_task",
            originalSource: "raw email body")
        await agent.ingestExternal([p], vaultPath: "/kb")
        let rec = try context.fetch(FetchDescriptor<Recommendation>()).first
        XCTAssertEqual(rec?.source, "jira")
        XCTAssertEqual(rec?.originalSource, "raw email body")
    }
}
