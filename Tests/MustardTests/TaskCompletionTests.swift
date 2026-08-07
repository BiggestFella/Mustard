import XCTest
import SwiftData
@testable import MustardKit

final class TaskCompletionTests: XCTestCase {
    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self, configurations: config
        )
        return ModelContext(container)
    }

    func test_complete_nonRecurring_marksDone_noSpawn() throws {
        let ctx = try makeContext()
        let t = MustardTask(title: "one-off")
        ctx.insert(t)
        TaskCompletion.complete(t, in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MustardTask>()).count, 1)
        XCTAssertEqual(t.status, .done)
    }

    func test_complete_recurring_marksDone_andSpawnsNextInstance() throws {
        let ctx = try makeContext()
        let t = MustardTask(title: "standup")
        t.recurrence = .daily
        t.dueAt = at("2026-06-12T00:00:00Z")
        ctx.insert(t)
        TaskCompletion.complete(t, in: ctx, now: at("2026-06-12T09:00:00Z"))
        let all = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(t.status, .done)
        let spawn = all.first { $0.uid != t.uid }
        XCTAssertEqual(spawn?.recurredFrom, t.uid)
        XCTAssertEqual(spawn?.status, .inbox)
        XCTAssertNil(spawn?.completedAt)
    }
}
