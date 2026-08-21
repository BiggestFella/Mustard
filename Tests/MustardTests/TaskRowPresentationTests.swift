import XCTest
@testable import MustardKit

/// Pins the condensed-row chip vocabulary (BAK-245): which pills a Today/Week
/// row shows, in the mockup-approved order, with UTC-pinned date/time strings
/// so AEST day-boundaries cannot flake.
final class TaskRowPresentationTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private let now = ISO8601DateFormatter().date(from: "2026-07-09T12:00:00Z")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func chips(
        isBlocked: Bool = false,
        isTimed: Bool = false,
        scheduledAt: Date? = nil,
        dueAt: Date? = nil,
        isDone: Bool = false,
        estimateMinutes: Int = 30,
        areaName: String? = nil,
        areaColorHex: String? = nil,
        owner: TaskOwner = .me,
        stage: TaskStage = .planned,
        subtaskDone: Int = 0,
        subtaskTotal: Int = 0
    ) -> [TaskRowChip] {
        TaskRowPresentation.chips(
            isBlocked: isBlocked,
            isTimed: isTimed,
            scheduledAt: scheduledAt,
            dueAt: dueAt,
            isDone: isDone,
            estimateMinutes: estimateMinutes,
            areaName: areaName,
            areaColorHex: areaColorHex,
            owner: owner,
            stage: stage,
            subtaskDone: subtaskDone,
            subtaskTotal: subtaskTotal,
            now: now,
            calendar: utc
        )
    }

    // MARK: - Bare task

    func test_bareTask_hasNoChips() {
        XCTAssertTrue(chips().isEmpty)
        XCTAssertFalse(TaskRowPresentation.hasChips(chips()))
    }

    // MARK: - Time chip (replaces the left gutter)

    func test_timedTask_emitsTimeChip_notUntimedStartOfDay() {
        let when = date("2026-07-09T09:00:00Z")
        XCTAssertEqual(
            chips(isTimed: true, scheduledAt: when),
            [.time("9:00 AM")]
        )
        // Planned-for-the-day (isTimed false) must not read as midnight.
        XCTAssertTrue(chips(isTimed: false, scheduledAt: when).isEmpty)
    }

    func test_eventTimeLabel_allDayVsClock() {
        XCTAssertEqual(
            TaskRowPresentation.eventTimeLabel(
                isAllDay: true, start: date("2026-07-09T00:00:00Z"), calendar: utc),
            "All day"
        )
        XCTAssertEqual(
            TaskRowPresentation.eventTimeLabel(
                isAllDay: false, start: date("2026-07-09T14:30:00Z"), calendar: utc),
            "2:30 PM"
        )
    }

    // MARK: - Due / estimate / area / subtasks

    func test_dueChip_overdueWhenPastAndOpen() {
        XCTAssertEqual(
            chips(dueAt: date("2026-07-08T09:00:00Z")),
            [.due(text: "Due Jul 8", overdue: true)]
        )
        XCTAssertEqual(
            chips(dueAt: date("2026-07-08T09:00:00Z"), isDone: true),
            [.due(text: "Due Jul 8", overdue: false)]
        )
        XCTAssertEqual(
            chips(dueAt: date("2026-07-10T09:00:00Z")),
            [.due(text: "Due Jul 10", overdue: false)]
        )
    }

    func test_estimateChip_hidesThirtyMinuteDefault() {
        XCTAssertTrue(chips(estimateMinutes: 30).isEmpty)
        XCTAssertEqual(chips(estimateMinutes: 90), [.estimate(90)])
        XCTAssertEqual(chips(estimateMinutes: 15), [.estimate(15)])
    }

    func test_areaChip_requiresAName() {
        XCTAssertEqual(
            chips(areaName: "DLA SDK", areaColorHex: "#378ADD"),
            [.area(name: "DLA SDK", colorHex: "#378ADD")]
        )
        XCTAssertTrue(chips(areaName: "  ", areaColorHex: "#378ADD").isEmpty)
        XCTAssertTrue(chips(areaName: nil, areaColorHex: "#378ADD").isEmpty)
    }

    func test_subtaskChip_onlyWhenThereAreSubtasks() {
        XCTAssertTrue(chips(subtaskDone: 0, subtaskTotal: 0).isEmpty)
        XCTAssertEqual(
            chips(subtaskDone: 1, subtaskTotal: 3),
            [.subtasks(done: 1, total: 3)]
        )
    }

    // MARK: - Agent stage

    func test_agentStageLabel_onlyForOpenAgentTasks() {
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .me, stage: .forAgent), nil)
        XCTAssertNil(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .done))
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .forAgent), "For agent")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .needsApproval), "Approve")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .queued), "Queued")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .inProgress), "Working…")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .needsInput), "Needs you")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .needsReview), "Review")
        XCTAssertEqual(TaskRowPresentation.agentStageLabel(owner: .agent, stage: .planned), "Agent")
    }

    func test_agentStageChip_usesSharedLabel() {
        XCTAssertEqual(
            chips(owner: .agent, stage: .needsReview),
            [.agentStage("Review")]
        )
        XCTAssertTrue(chips(owner: .agent, stage: .done).isEmpty)
    }

    // MARK: - Order (mockup 2026-07-09)

    func test_chipOrder_blockedTimeDueEstimateAreaAgentSubtasks() {
        let when = date("2026-07-09T09:00:00Z")
        XCTAssertEqual(
            chips(
                isBlocked: true,
                isTimed: true,
                scheduledAt: when,
                dueAt: date("2026-07-10T09:00:00Z"),
                estimateMinutes: 45,
                areaName: "Admin",
                areaColorHex: "#3E8E7E",
                owner: .agent,
                stage: .queued,
                subtaskDone: 0,
                subtaskTotal: 2
            ),
            [
                .blocked,
                .time("9:00 AM"),
                .due(text: "Due Jul 10", overdue: false),
                .estimate(45),
                .area(name: "Admin", colorHex: "#3E8E7E"),
                .agentStage("Queued"),
                .subtasks(done: 0, total: 2),
            ]
        )
    }

    // MARK: - Convenience over MustardTask

    func test_chipsForTask_readsTimedDueAndDefaultEstimate() {
        let task = MustardTask(title: "Standup", scheduledAt: date("2026-07-09T09:00:00Z"))
        task.isTimed = true
        task.dueAt = date("2026-07-10T00:00:00Z")
        XCTAssertEqual(
            TaskRowPresentation.chips(for: task, now: now, calendar: utc),
            [.time("9:00 AM"), .due(text: "Due Jul 10", overdue: false)]
        )
        XCTAssertTrue(TaskRowPresentation.hasChips(for: task, now: now, calendar: utc))
    }

    func test_densityTokens_condensedIsTheDefaultDetailCardRow() {
        XCTAssertEqual(TaskRowDensity.condensed.titleSize, 15.5)
        XCTAssertEqual(TaskRowDensity.tighter.titleSize, 13.5)
        XCTAssertGreaterThan(TaskRowDensity.condensed.vPadding, TaskRowDensity.tighter.vPadding)
    }
}
