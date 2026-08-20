import XCTest
@testable import MustardKit

/// Pins the opened-task read-first rules (BAK-244): when the sheet starts in
/// the property grid, what the DETAILS list includes, and the header location
/// line. Date rows use a pinned UTC calendar so AEST day-boundaries cannot flake.
final class TaskDetailPresentationTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - startsInEditMode

    func test_startsInEditMode_emptyAndNewTaskPlaceholder() {
        XCTAssertTrue(TaskDetailPresentation.startsInEditMode(title: ""))
        XCTAssertTrue(TaskDetailPresentation.startsInEditMode(title: "   "))
        XCTAssertTrue(TaskDetailPresentation.startsInEditMode(title: "New task"))
        XCTAssertTrue(TaskDetailPresentation.startsInEditMode(title: "new task"))
    }

    func test_startsInEditMode_realTitleStaysReadFirst() {
        XCTAssertFalse(TaskDetailPresentation.startsInEditMode(title: "Draft DLA 5.2 release notes"))
        XCTAssertFalse(TaskDetailPresentation.startsInEditMode(title: "New task for Kamil"))
    }

    // MARK: - locationLine

    func test_locationLine_combinesAreaAndList() {
        XCTAssertEqual(TaskDetailPresentation.locationLine(area: "DLA SDK", list: "Release"),
                       "DLA SDK · Release")
    }

    func test_locationLine_dedupesIdenticalNames() {
        XCTAssertEqual(TaskDetailPresentation.locationLine(area: "Admin", list: "Admin"),
                       "Admin")
    }

    func test_locationLine_singleSideAndEmpty() {
        XCTAssertEqual(TaskDetailPresentation.locationLine(area: "Errands", list: nil), "Errands")
        XCTAssertEqual(TaskDetailPresentation.locationLine(area: nil, list: "Inbox"), "Inbox")
        XCTAssertNil(TaskDetailPresentation.locationLine(area: nil, list: nil))
        XCTAssertNil(TaskDetailPresentation.locationLine(area: "  ", list: ""))
    }

    // MARK: - owner glance / agent context

    func test_ownerGlance() {
        XCTAssertEqual(TaskDetailPresentation.ownerGlance(.me), "You")
        XCTAssertEqual(TaskDetailPresentation.ownerGlance(.agent), "✦ Agent")
    }

    func test_hasAgentContext() {
        XCTAssertFalse(TaskDetailPresentation.hasAgentContext(
            confidence: nil, why: "", draft: "", isGated: false))
        XCTAssertTrue(TaskDetailPresentation.hasAgentContext(
            confidence: 0.8, why: "", draft: "", isGated: false))
        XCTAssertTrue(TaskDetailPresentation.hasAgentContext(
            confidence: nil, why: "  because  ", draft: "", isGated: false))
        XCTAssertTrue(TaskDetailPresentation.hasAgentContext(
            confidence: nil, why: "", draft: "Hi Kamil", isGated: false))
        XCTAssertTrue(TaskDetailPresentation.hasAgentContext(
            confidence: nil, why: "", draft: "", isGated: true))
    }

    // MARK: - DETAILS rows

    func test_detailRows_coreFieldsAlwaysPresent() {
        let rows = TaskDetailPresentation.detailRows(
            owner: .me, stage: .planned, priority: .normal,
            area: nil, list: nil, estimateMinutes: 30,
            dueAt: nil, scheduledAt: nil, isTimed: false,
            recurrence: nil, parentTitle: nil, blockedByTitle: nil,
            blockedReason: "", actionType: nil,
            calendar: utc)
        XCTAssertEqual(rows.map(\.label), ["Assignee", "Stage", "Priority", "Area", "Estimate"])
        XCTAssertEqual(rows.first { $0.label == "Assignee" }?.value, "You")
        XCTAssertEqual(rows.first { $0.label == "Stage" }?.value, "Planned")
        XCTAssertEqual(rows.first { $0.label == "Priority" }?.value, "Normal")
        XCTAssertEqual(rows.first { $0.label == "Area" }?.value, "None")
        XCTAssertEqual(rows.first { $0.label == "Estimate" }?.value, "30m")
    }

    func test_detailRows_optionalSchedulingAndRelations() {
        let due = date("2026-08-17T00:00:00Z")
        let scheduled = date("2026-08-18T09:00:00Z")
        let rows = TaskDetailPresentation.detailRows(
            owner: .agent, stage: .scheduled, priority: .high,
            area: "DLA SDK", list: "Release", estimateMinutes: 90,
            dueAt: due, scheduledAt: scheduled, isTimed: true,
            recurrence: .weekly, parentTitle: "Prep DLA 5.2 release",
            blockedByTitle: "Thales SDK sync", blockedReason: "waiting on BLE",
            actionType: .ticket, calendar: utc)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Assignee"], "✦ Agent")
        XCTAssertEqual(byLabel["Area"], "DLA SDK")
        XCTAssertEqual(byLabel["List"], "Release")
        XCTAssertEqual(byLabel["Estimate"], "90m")
        XCTAssertEqual(byLabel["Due"], "17 Aug 2026")
        XCTAssertEqual(byLabel["Scheduled"], "18 Aug 2026, 09:00")
        XCTAssertEqual(byLabel["Repeats"], "Weekly")
        XCTAssertEqual(byLabel["Parent"], "Prep DLA 5.2 release")
        XCTAssertEqual(byLabel["Blocked by"], "Thales SDK sync")
        XCTAssertEqual(byLabel["Blocked reason"], "waiting on BLE")
        XCTAssertEqual(byLabel["Action"], "Create Shortcut")
    }

    func test_detailRows_untimedScheduleOmitsClock() {
        let scheduled = date("2026-08-18T09:00:00Z")
        let rows = TaskDetailPresentation.detailRows(
            owner: .me, stage: .scheduled, priority: .normal,
            area: "Admin", list: "Admin", estimateMinutes: 30,
            dueAt: nil, scheduledAt: scheduled, isTimed: false,
            recurrence: nil, parentTitle: nil, blockedByTitle: nil,
            blockedReason: "", actionType: nil, calendar: utc)
        XCTAssertNil(rows.first { $0.label == "List" },
                     "identical area/list names should not emit a duplicate List row")
        XCTAssertEqual(rows.first { $0.label == "Scheduled" }?.value, "18 Aug 2026")
    }

    func test_detailRows_fromTask_readsRelationships() {
        let parent = MustardTask(title: "Parent work")
        let blocker = MustardTask(title: "Blocker")
        let task = MustardTask(title: "Child")
        task.owner = .me
        task.stage = .blocked
        task.parent = parent
        task.blockedByTask = blocker
        task.blockedReason = "needs review"
        let rows = TaskDetailPresentation.detailRows(for: task, calendar: utc)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Parent"], "Parent work")
        XCTAssertEqual(byLabel["Blocked by"], "Blocker")
        XCTAssertEqual(byLabel["Blocked reason"], "needs review")
    }

    func test_glanceShowsEstimate_alwaysOnOpenedTask() {
        XCTAssertTrue(TaskDetailPresentation.showsGlanceEstimate(30))
        XCTAssertTrue(TaskDetailPresentation.showsGlanceEstimate(90))
    }
}
