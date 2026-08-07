import XCTest
import SwiftData
@testable import MustardKit

final class AgentAreaStampingTests: XCTestCase {
    @MainActor
    private func ctx() throws -> ModelContext {
        let c = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    /// The gap that dead-ended the triage→execute path: an approved outward rec must
    /// land a `.queued` task that carries the area (from the rec's folder-name project),
    /// so the bridge export can route it.
    @MainActor
    func test_approveOutwardRec_stampsArea_andQueues() async throws {
        let context = try ctx()
        let svc = AgentService(context: context, claude: { _, _ in .init(ok: true, text: "") })
        let rec = Recommendation(title: "Reply to Kamil", actionType: "draft_email", vaultPath: "/x")
        rec.project = "DL-Knowledge-Base"            // the real stored form
        context.insert(rec)

        await svc.decide(rec, .approved)

        let task = try XCTUnwrap(rec.task)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.list?.area?.name, "Digital Licence")   // routes to DL export
    }

    /// A second approved DL rec reuses the same Area/list (find-or-create, no duplicates).
    @MainActor
    func test_secondRec_reusesArea() async throws {
        let context = try ctx()
        let svc = AgentService(context: context, claude: { _, _ in .init(ok: true, text: "") })
        for title in ["a", "b"] {
            let r = Recommendation(title: title, actionType: "ticket_write", vaultPath: "/x")
            r.project = "DL-Knowledge-Base"; context.insert(r)
            await svc.decide(r, .approved)
        }
        let areas = try context.fetch(FetchDescriptor<Area>()).filter { $0.name == "Digital Licence" }
        XCTAssertEqual(areas.count, 1, "should not create duplicate areas")
    }
}
