import Foundation

/// Pure presentation for the opened-task detail (BAK-244).
///
/// The sheet is **read-first**: opening a real personal task shows a calm
/// document (header, notes, DETAILS, tags, subtasks). Edit flips to the
/// existing property grid. Untitled / "+ New task" placeholders start in
/// the grid so the first keystroke has somewhere to go.
///
/// Views only render these values — no date/area/edit decisions live in SwiftUI.
public enum TaskDetailPresentation {
    public struct Row: Equatable, Identifiable {
        public var id: String { label }
        public let label: String
        public let value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Fresh board "+ New task" cards and blank drafts open in the property grid.
    public static func startsInEditMode(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed.compare("New task", options: .caseInsensitive) == .orderedSame
    }

    public static func ownerGlance(_ owner: TaskOwner) -> String {
        owner == .agent ? "✦ Agent" : "You"
    }

    /// Header path: `Area · List`. The list is omitted when it repeats the area name.
    public static func locationLine(area: String?, list: String?) -> String? {
        let a = area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let l = list?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (a.isEmpty, l.isEmpty) {
        case (true, true): return nil
        case (false, true): return a
        case (true, false): return l
        case (false, false) where a == l: return a
        case (false, false): return "\(a) · \(l)"
        }
    }

    public static func locationLine(for task: MustardTask) -> String? {
        locationLine(area: task.list?.area?.name, list: task.list?.name)
    }

    public static func hasAgentContext(
        confidence: Double?, why: String, draft: String, isGated: Bool
    ) -> Bool {
        if isGated { return true }
        if confidence != nil { return true }
        if !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    /// Opened-task glance always shows estimate (unlike the condensed row, which
    /// hides the 30m default so a bare task stays quiet).
    public static func showsGlanceEstimate(_ minutes: Int) -> Bool {
        _ = minutes
        return true
    }

    public static func detailRows(
        owner: TaskOwner,
        stage: TaskStage,
        priority: TaskPriority,
        area: String?,
        list: String?,
        estimateMinutes: Int,
        dueAt: Date?,
        scheduledAt: Date?,
        isTimed: Bool,
        recurrence: Recurrence?,
        parentTitle: String?,
        blockedByTitle: String?,
        blockedReason: String,
        actionType: RecommendationAction?,
        calendar: Calendar
    ) -> [Row] {
        var rows: [Row] = [
            Row(label: "Assignee", value: ownerGlance(owner)),
            Row(label: "Stage", value: stage.label),
            Row(label: "Priority", value: priority.label),
            Row(label: "Area", value: {
                let name = area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty ? "None" : name
            }()),
        ]
        let listName = list?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let areaName = area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !listName.isEmpty, listName != areaName {
            rows.append(Row(label: "List", value: listName))
        }
        rows.append(Row(label: "Estimate", value: "\(estimateMinutes)m"))
        if let dueAt {
            rows.append(Row(label: "Due", value: formatDay(dueAt, calendar: calendar)))
        }
        if let scheduledAt {
            rows.append(Row(
                label: "Scheduled",
                value: isTimed
                    ? formatDayTime(scheduledAt, calendar: calendar)
                    : formatDay(scheduledAt, calendar: calendar)
            ))
        }
        if let recurrence {
            rows.append(Row(label: "Repeats", value: recurrence.label))
        }
        if let parentTitle, !parentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(Row(label: "Parent", value: parentTitle))
        }
        if let blockedByTitle, !blockedByTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(Row(label: "Blocked by", value: blockedByTitle))
        }
        let reason = blockedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            rows.append(Row(label: "Blocked reason", value: reason))
        }
        if let actionType {
            rows.append(Row(label: "Action", value: actionType.label))
        }
        return rows
    }

    public static func detailRows(
        for task: MustardTask, calendar: Calendar
    ) -> [Row] {
        detailRows(
            owner: task.owner,
            stage: task.stage,
            priority: task.priority,
            area: task.list?.area?.name,
            list: task.list?.name,
            estimateMinutes: task.estimateMinutes,
            dueAt: task.dueAt,
            scheduledAt: task.scheduledAt,
            isTimed: task.isTimed,
            recurrence: task.recurrence,
            parentTitle: task.parent?.title,
            blockedByTitle: task.blockedByTask?.title,
            blockedReason: task.blockedReason,
            actionType: task.actionType,
            calendar: calendar
        )
    }

    // MARK: - Date strings (calendar-injected; POSIX so tests pin)

    private static func formatDay(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, format: "d MMM yyyy").string(from: date)
    }

    private static func formatDayTime(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar, format: "d MMM yyyy, HH:mm").string(from: date)
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
