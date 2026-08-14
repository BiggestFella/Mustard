import XCTest
@testable import MustardKit

final class DayPlannerTests: XCTestCase {
    // Pin the calendar to UTC so ISO "Z" fixtures bucket deterministically
    // regardless of the machine's timezone (AEST is +10: 15:00Z is tomorrow).
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func test_carryForward_stampsMovedTasks_only() {
        let cal = utcCalendar()
        let today = Date(timeIntervalSince1970: 1_751_760_000)
        let stale = MustardTask(title: "old", scheduledAt: today.addingTimeInterval(-86_400))
        let todayTask = MustardTask(title: "today", scheduledAt: today.addingTimeInterval(3_600))
        let unscheduled = MustardTask(title: "loose")

        DayPlanner.carryForward([stale, todayTask, unscheduled], to: today, calendar: cal)

        XCTAssertNotNil(stale.carriedForwardAt)
        XCTAssertTrue(cal.isDate(stale.carriedForwardAt!, inSameDayAs: today))
        XCTAssertNil(todayTask.carriedForwardAt)      // already on today — not moved, not stamped
        XCTAssertNil(unscheduled.carriedForwardAt)
    }

    func test_tasksForDay_returnsOnlySameDayScheduled_sortedByTime() {
        let day = at("2026-06-12T00:00:00Z")
        let a = MustardTask(title: "late", scheduledAt: at("2026-06-12T15:00:00Z"))
        let b = MustardTask(title: "early", scheduledAt: at("2026-06-12T09:00:00Z"))
        let other = MustardTask(title: "tomorrow", scheduledAt: at("2026-06-13T09:00:00Z"))
        let unscheduled = MustardTask(title: "loose")
        let result = DayPlanner.tasksForDay([a, b, other, unscheduled], day: day, calendar: cal)
        XCTAssertEqual(result.map(\.title), ["early", "late"])
    }

    func test_unscheduled_returnsOpenTasksWithNoDate() {
        let scheduled = MustardTask(title: "s", scheduledAt: at("2026-06-12T09:00:00Z"))
        let open = MustardTask(title: "open")
        let done = MustardTask(title: "done")
        done.markDone()
        let result = DayPlanner.unscheduled([scheduled, open, done])
        XCTAssertEqual(result.map(\.title), ["open"])
    }

    func test_carryForward_movesIncompletePastTasksToToday_preservingTimeOfDay() {
        let today = at("2026-06-12T00:00:00Z")
        let stale = MustardTask(title: "stale", scheduledAt: at("2026-06-10T14:30:00Z"))
        let doneStale = MustardTask(title: "doneStale", scheduledAt: at("2026-06-10T14:30:00Z"))
        doneStale.markDone()
        DayPlanner.carryForward([stale, doneStale], to: today, calendar: cal)

        let comps = cal.dateComponents([.day, .hour, .minute], from: stale.scheduledAt!)
        XCTAssertEqual(comps.day, 12)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(doneStale.scheduledAt, at("2026-06-10T14:30:00Z"))
    }

    func test_carryForward_excludesRepositoryProjectionWhileMovingOrdinaryTask() {
        let today = at("2026-06-12T00:00:00Z")
        let oldDate = at("2026-06-10T14:30:00Z")
        let projection = MustardTask(title: "Repository decision", scheduledAt: oldDate)
        projection.source = CodeHeroesDecisionPolicy.source
        let ordinary = MustardTask(title: "Ordinary task", scheduledAt: oldDate)

        DayPlanner.carryForward([projection, ordinary], to: today, calendar: cal)

        XCTAssertEqual(projection.scheduledAt, oldDate)
        XCTAssertNil(projection.carriedForwardAt)
        XCTAssertTrue(cal.isDate(ordinary.scheduledAt!, inSameDayAs: today))
        XCTAssertTrue(cal.isDate(ordinary.carriedForwardAt!, inSameDayAs: today))
    }

    func test_upcoming_returnsOpenScheduledAfterNow_soonestFirst_limited() {
        let now = at("2026-06-12T10:00:00Z")
        let soon = MustardTask(title: "soon", scheduledAt: at("2026-06-12T11:00:00Z"))
        let later = MustardTask(title: "later", scheduledAt: at("2026-06-12T15:00:00Z"))
        let past = MustardTask(title: "past", scheduledAt: at("2026-06-12T09:00:00Z"))
        let done = MustardTask(title: "done", scheduledAt: at("2026-06-12T12:00:00Z")); done.markDone()
        let unsched = MustardTask(title: "unsched")
        let result = DayPlanner.upcoming([later, soon, past, done, unsched], after: now, limit: 2)
        XCTAssertEqual(result.map(\.title), ["soon", "later"])
    }

    func test_carryForward_leavesTodayAndFutureTasksAlone() {
        let today = at("2026-06-12T00:00:00Z")
        let todays = MustardTask(title: "today", scheduledAt: at("2026-06-12T09:00:00Z"))
        let future = MustardTask(title: "future", scheduledAt: at("2026-06-14T09:00:00Z"))
        DayPlanner.carryForward([todays, future], to: today, calendar: cal)
        XCTAssertEqual(todays.scheduledAt, at("2026-06-12T09:00:00Z"))
        XCTAssertEqual(future.scheduledAt, at("2026-06-14T09:00:00Z"))
    }

    func test_upcoming_excludesBlockedTasks() {
        let now = at("2026-06-12T10:00:00Z")
        let open = MustardTask(title: "open", scheduledAt: at("2026-06-12T11:00:00Z"))
        let blocked = MustardTask(title: "blocked", scheduledAt: at("2026-06-12T11:30:00Z"))
        blocked.blockedReason = "waiting on review"
        let result = DayPlanner.upcoming([open, blocked], after: now, limit: 5)
        XCTAssertEqual(result.map(\.title), ["open"])
    }

    func test_agenda_mergesTasksAndEventsChronologically_untimedLast() {
        let day = at("2026-06-12T00:00:00Z")

        let review = MustardTask(title: "Review PR", scheduledAt: at("2026-06-12T09:30:00Z"))
        review.isTimed = true

        let standup = MustardTask(title: "Team stand-up", scheduledAt: at("2026-06-12T09:00:00Z"))
        standup.isTimed = true
        standup.markDone()

        let anytime = MustardTask(title: "Reply to ACME", scheduledAt: at("2026-06-12T00:00:00Z"))
        anytime.isTimed = false

        let elsewhere = MustardTask(title: "Tomorrow's task", scheduledAt: at("2026-06-13T09:00:00Z"))
        elsewhere.isTimed = true

        let sync = CalendarEvent(
            title: "Design sync", start: at("2026-06-12T11:00:00Z"), end: at("2026-06-12T11:30:00Z")
        )
        let allDay = CalendarEvent(
            title: "Company holiday", start: at("2026-06-12T00:00:00Z"), end: at("2026-06-13T00:00:00Z"),
            isAllDay: true
        )

        let result = DayPlanner.agenda(
            tasks: [review, standup, anytime, elsewhere], events: [sync, allDay], day: day, calendar: cal
        )

        XCTAssertEqual(
            result.map(\.title),
            ["Team stand-up", "Review PR", "Design sync", "Reply to ACME", "Company holiday"]
        )
    }

    func test_agenda_tagLabelAndColorComeFromTaskListArea() {
        let day = at("2026-06-12T00:00:00Z")
        let area = Area(name: "DLA SDK", colorHex: "#378ADD")
        let list = TaskList(name: "SDK work", area: area)
        let task = MustardTask(title: "Review DLA SDK pull request", scheduledAt: at("2026-06-12T09:30:00Z"))
        task.isTimed = true
        task.list = list

        let result = DayPlanner.agenda(tasks: [task], events: [], day: day, calendar: cal)

        XCTAssertEqual(result.first?.tagLabel, "DLA SDK")
        XCTAssertEqual(result.first?.tagColorHex, "#378ADD")
    }

    func test_agenda_eventsCarryJoinURL_andAreNeverDone() {
        let day = at("2026-06-12T00:00:00Z")
        let meeting = CalendarEvent(
            title: "Design sync", start: at("2026-06-12T11:00:00Z"), end: at("2026-06-12T11:30:00Z"),
            joinURL: "https://meet.example.com/design-sync"
        )

        let result = DayPlanner.agenda(tasks: [], events: [meeting], day: day, calendar: cal)

        XCTAssertEqual(result.first?.joinURL, "https://meet.example.com/design-sync")
        XCTAssertEqual(result.first?.isDone, false)
    }

    func test_agenda_taskIsDoneReflectsStage() {
        let day = at("2026-06-12T00:00:00Z")
        let task = MustardTask(title: "Draft notes", scheduledAt: at("2026-06-12T14:00:00Z"))
        task.isTimed = true
        task.markDone()

        let result = DayPlanner.agenda(tasks: [task], events: [], day: day, calendar: cal)

        XCTAssertEqual(result.first?.isDone, true)
    }
}
