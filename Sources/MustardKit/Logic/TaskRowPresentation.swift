import Foundation

/// One pill on a condensed task row (BAK-245). Order is the mockup-approved
/// strip: blocked · time · due · estimate · area · agent-stage · subtasks.
/// Views render these with the shared `MetaChip` primitive so a task looks
/// the same as a row, a board card, or the opened detail sheet.
public enum TaskRowChip: Equatable {
    case blocked
    case time(String)
    case due(text: String, overdue: Bool)
    case estimate(Int)
    case area(name: String, colorHex: String)
    case agentStage(String)
    case subtasks(done: Int, total: Int)
}

/// Pure presentation for Today/Week/list rows (BAK-245). Views only render;
/// date math and "which chips exist" live here so they can be UTC-pinned.
public enum TaskRowPresentation {
    /// Estimate the row treats as "nothing to say" — the model default.
    public static let defaultEstimateMinutes = 30

    /// Short agent-stage label for an agent-owned open task; nil = no chip.
    /// Shared by the row chip strip and `DelegationBadge`.
    public static func agentStageLabel(owner: TaskOwner, stage: TaskStage) -> String? {
        guard owner == .agent, stage != .done else { return nil }
        switch stage {
        case .forAgent: return "For agent"
        case .needsApproval: return "Approve"
        case .queued: return "Queued"
        case .inProgress: return "Working…"
        case .needsInput: return "Needs you"
        case .needsReview: return "Review"
        default: return "Agent"
        }
    }

    public static func hasChips(_ chips: [TaskRowChip]) -> Bool { !chips.isEmpty }

    public static func hasChips(
        for task: MustardTask, now: Date = .now, calendar: Calendar = .current
    ) -> Bool {
        !chips(for: task, now: now, calendar: calendar).isEmpty
    }

    public static func chips(
        for task: MustardTask, now: Date = .now, calendar: Calendar = .current
    ) -> [TaskRowChip] {
        let progress = task.subtaskProgress
        return chips(
            isBlocked: task.isBlocked,
            isTimed: task.isTimed,
            scheduledAt: task.scheduledAt,
            dueAt: task.dueAt,
            isDone: task.stage == .done,
            estimateMinutes: task.estimateMinutes,
            areaName: task.list?.area?.name,
            areaColorHex: task.list?.area?.colorHex,
            owner: task.owner,
            stage: task.stage,
            subtaskDone: progress.done,
            subtaskTotal: progress.total,
            now: now,
            calendar: calendar
        )
    }

    public static func chips(
        isBlocked: Bool,
        isTimed: Bool,
        scheduledAt: Date?,
        dueAt: Date?,
        isDone: Bool,
        estimateMinutes: Int,
        areaName: String?,
        areaColorHex: String?,
        owner: TaskOwner,
        stage: TaskStage,
        subtaskDone: Int,
        subtaskTotal: Int,
        now: Date,
        calendar: Calendar
    ) -> [TaskRowChip] {
        var out: [TaskRowChip] = []
        if isBlocked { out.append(.blocked) }
        if let time = timeLabel(isTimed: isTimed, scheduledAt: scheduledAt, calendar: calendar) {
            out.append(.time(time))
        }
        if let dueAt {
            let overdue = dueAt < now && !isDone
            out.append(.due(text: "Due \(formatDay(dueAt, calendar: calendar))", overdue: overdue))
        }
        if estimateMinutes != defaultEstimateMinutes {
            out.append(.estimate(estimateMinutes))
        }
        let area = areaName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !area.isEmpty {
            let hex = areaColorHex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(.area(
                name: area,
                colorHex: hex.isEmpty ? Theme.Palette.areaGreyHex : hex
            ))
        }
        if let stage = agentStageLabel(owner: owner, stage: stage) {
            out.append(.agentStage(stage))
        }
        if subtaskTotal > 0 {
            out.append(.subtasks(done: subtaskDone, total: subtaskTotal))
        }
        return out
    }

    /// Clock chip for a calendar event on the spine. All-day events say "All day"
    /// rather than a midnight time.
    public static func eventTimeLabel(isAllDay: Bool, start: Date, calendar: Calendar) -> String {
        isAllDay ? "All day" : formatTime(start, calendar: calendar)
    }

    public static func timeLabel(
        isTimed: Bool, scheduledAt: Date?, calendar: Calendar
    ) -> String? {
        guard isTimed, let scheduledAt else { return nil }
        return formatTime(scheduledAt, calendar: calendar)
    }

    // MARK: - Date strings (calendar-injected; POSIX so tests pin)

    private static func formatDay(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, format: "MMM d").string(from: date)
    }

    private static func formatTime(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, format: "h:mm a").string(from: date)
    }

    private static func formatter(calendar: Calendar, format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
