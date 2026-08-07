import XCTest
@testable import MustardKit

final class TimelineSpineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// A timed task on the given day/time.
    private func timed(_ title: String, _ iso: String, owner: TaskOwner = .me) -> MustardTask {
        let t = MustardTask(title: title, owner: owner, scheduledAt: at(iso))
        t.isTimed = true
        return t
    }

    private let ref = "2026-06-12T10:00:00Z"   // today = 2026-06-12, now = 10:00

    func test_build_sectionsTodayTomorrowAndDatedDays_withLabels() {
        let tasks = [
            timed("today am", "2026-06-12T09:00:00Z"),
            timed("tomorrow", "2026-06-13T09:00:00Z"),
            timed("in three days", "2026-06-15T09:00:00Z"),
        ]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref), calendar: cal)
        XCTAssertEqual(spine.map(\.label), [.today, .tomorrow, .other(at("2026-06-15T00:00:00Z"))])
        XCTAssertEqual(spine[0].items.map(\.title), ["today am"])
        XCTAssertEqual(spine[1].items.map(\.title), ["tomorrow"])
        XCTAssertEqual(spine[2].items.map(\.title), ["in three days"])
    }

    func test_build_alwaysKeepsToday_evenWhenEmpty_andCollapsesEmptyForwardDays() {
        let tasks = [timed("tomorrow only", "2026-06-13T09:00:00Z")]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref), calendar: cal)
        XCTAssertEqual(spine.map(\.label), [.today, .tomorrow])
        XCTAssertTrue(spine[0].items.isEmpty)   // today kept for its empty state
    }

    func test_build_respectsHorizonCutoff() {
        let tasks = [
            timed("in horizon", "2026-06-18T09:00:00Z"),   // +6 days
            timed("beyond horizon", "2026-06-22T09:00:00Z"), // +10 days
        ]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref),
                                        horizonDays: 7, calendar: cal)
        let titles = spine.flatMap { $0.items.map(\.title) }
        XCTAssertTrue(titles.contains("in horizon"))
        XCTAssertFalse(titles.contains("beyond horizon"))
    }

    func test_build_excludesFocusPinnedTasksFromToday_only() {
        let pinned = timed("pinned", "2026-06-12T09:00:00Z")
        pinned.focusOnDay = at("2026-06-12T00:00:00Z")
        let normal = timed("normal", "2026-06-12T11:00:00Z")
        let spine = TimelineSpine.build(tasks: [pinned, normal], events: [],
                                        reference: at(ref), calendar: cal)
        XCTAssertEqual(spine[0].items.map(\.title), ["normal"])   // pinned excluded from today
    }

    func test_build_interleavesEventsAndTasksByTime() {
        let task = timed("standup task", "2026-06-12T09:30:00Z")
        let event = CalendarEvent(); event.title = "9am meeting"
        event.start = at("2026-06-12T09:00:00Z"); event.end = at("2026-06-12T09:30:00Z")
        let spine = TimelineSpine.build(tasks: [task], events: [event],
                                        reference: at(ref), calendar: cal)
        XCTAssertEqual(spine[0].items.map(\.title), ["9am meeting", "standup task"])
    }

    func test_isPast_splitsAroundReference() {
        let past = timed("past", "2026-06-12T09:00:00Z")
        let future = timed("future", "2026-06-12T15:00:00Z")
        let spine = TimelineSpine.build(tasks: [past, future], events: [],
                                        reference: at(ref), calendar: cal)
        let items = spine[0].items
        XCTAssertTrue(TimelineSpine.isPast(items[0], relativeTo: at(ref)))
        XCTAssertFalse(TimelineSpine.isPast(items[1], relativeTo: at(ref)))
    }
}
