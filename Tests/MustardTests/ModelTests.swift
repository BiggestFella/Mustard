import XCTest
import SwiftData
@testable import MustardKit

final class ModelTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self, configurations: config
        )
        return ModelContext(container)
    }

    func test_newTask_defaultsToInboxOwnedByMe() throws {
        let task = MustardTask(title: "Draft notes")
        XCTAssertEqual(task.status, .inbox)
        XCTAssertEqual(task.owner, .me)
        XCTAssertNil(task.scheduledAt)
    }

    func test_markDone_setsStatusAndCompletedAt() throws {
        let task = MustardTask(title: "x")
        let when = Date(timeIntervalSince1970: 1_000_000)
        task.markDone(now: when)
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.completedAt, when)
    }

    func test_insertAndFetch_roundTrips() throws {
        let ctx = try makeContext()
        ctx.insert(MustardTask(title: "Persisted"))
        let fetched = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.title, "Persisted")
    }

    func test_statusAccessor_survivesRawRoundTrip() throws {
        let task = MustardTask(title: "x")
        task.status = .inProgress
        XCTAssertEqual(task.statusRaw, "inProgress")
        XCTAssertEqual(task.status, .inProgress)
    }

    func test_deletingList_keepsTasks_unfilesThem() throws {
        let ctx = try makeContext()
        let area = Area(name: "Work")
        let list = TaskList(name: "Dev", area: area)
        let task = MustardTask(title: "Filed")
        task.list = list
        ctx.insert(area); ctx.insert(list); ctx.insert(task)
        try ctx.save()

        ctx.delete(list)
        try ctx.save()

        let tasks = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(tasks.count, 1, "task should survive its list's deletion")
        XCTAssertNil(tasks.first?.list, "task should be unfiled, not deleted")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TaskList>()).count, 0)
    }

    func test_deletingArea_keepsLists_orphansThem() throws {
        let ctx = try makeContext()
        let area = Area(name: "Work")
        let list = TaskList(name: "Dev", area: area)
        ctx.insert(area); ctx.insert(list)
        try ctx.save()

        ctx.delete(area)
        try ctx.save()

        let lists = try ctx.fetch(FetchDescriptor<TaskList>())
        XCTAssertEqual(lists.count, 1, "list should survive its area's deletion")
        XCTAssertNil(lists.first?.area, "list should be area-less, not deleted")
    }

    func test_priority_defaultsToNormal_andSurvivesRawRoundTrip() throws {
        let task = MustardTask(title: "x")
        XCTAssertEqual(task.priority, .normal)
        task.priority = .high
        XCTAssertEqual(task.priorityRaw, "high")
        XCTAssertEqual(task.priority, .high)
    }

    func test_recurrence_defaultsToNil_andSurvivesRawRoundTrip() throws {
        let task = MustardTask(title: "x")
        XCTAssertNil(task.recurrence)
        task.recurrence = .weekly
        XCTAssertEqual(task.recurrenceRaw, "weekly")
        XCTAssertEqual(task.recurrence, .weekly)
        task.recurrence = nil
        XCTAssertNil(task.recurrenceRaw)
    }

    func test_isBlocked_reflectsBlockedReason() throws {
        let task = MustardTask(title: "x")
        XCTAssertFalse(task.isBlocked)
        task.blockedReason = "waiting on Kamil"
        XCTAssertTrue(task.isBlocked)
    }

    func test_markDone_cascadesToOpenSubtasks_settingAutoCompleted() throws {
        let ctx = try makeContext()
        let parent = MustardTask(title: "parent")
        let c1 = MustardTask(title: "c1")
        let c2 = MustardTask(title: "c2")
        ctx.insert(parent); ctx.insert(c1); ctx.insert(c2)
        c1.parent = parent
        c2.parent = parent
        let when = Date(timeIntervalSince1970: 2_000_000)
        parent.markDone(now: when)
        XCTAssertEqual(parent.status, .done)
        XCTAssertFalse(parent.autoCompleted)        // manually completed
        XCTAssertEqual(c1.status, .done)
        XCTAssertTrue(c1.autoCompleted)             // cascaded
        XCTAssertEqual(c2.status, .done)
    }

    func test_subtaskProgress_countsDoneOverTotal() throws {
        let ctx = try makeContext()
        let parent = MustardTask(title: "parent")
        let c1 = MustardTask(title: "c1")
        let c2 = MustardTask(title: "c2")
        ctx.insert(parent); ctx.insert(c1); ctx.insert(c2)
        c1.parent = parent; c2.parent = parent
        c1.markDone()
        XCTAssertEqual(parent.subtaskProgress.done, 1)
        XCTAssertEqual(parent.subtaskProgress.total, 2)
    }
}
