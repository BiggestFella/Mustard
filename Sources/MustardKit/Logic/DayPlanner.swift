import Foundation

/// One row of the merged today-agenda (notch §6a redesign): a task or an
/// event, whichever it wraps, with the display fields already resolved so
/// views don't need to branch on `kind` except to decide tap/toggle targets.
public struct AgendaItem: Identifiable {
    public enum Kind {
        case task(MustardTask)
        case event(CalendarEvent)
    }

    public let id: String
    public let kind: Kind
    /// `nil` means untimed — sorts last, rendered as "Any".
    public let time: Date?
    public let title: String
    public let isDone: Bool
    public let tagLabel: String?
    public let tagColorHex: String?
    public let joinURL: String?
}

/// Pure day-planning logic: no SwiftData queries, no views.
/// Operates on in-memory tasks so it stays trivially unit-testable.
public enum DayPlanner {
    /// Tasks scheduled on `day`, ordered by time.
    public static func tasksForDay(
        _ tasks: [MustardTask], day: Date, calendar: Calendar = .current
    ) -> [MustardTask] {
        tasks
            .filter { task in
                guard let when = task.scheduledAt else { return false }
                return calendar.isDate(when, inSameDayAs: day)
            }
            .sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
    }

    /// Open tasks with no scheduled date — the inbox rail.
    public static func unscheduled(_ tasks: [MustardTask]) -> [MustardTask] {
        tasks.filter { $0.scheduledAt == nil && $0.stage.isOpen }
    }

    /// (done, total) over the tasks scheduled on `day` — drives Today's progress bar
    /// "N of M done" (BAK-103). Derived; never stored.
    public static func dayProgress(
        _ tasks: [MustardTask], day: Date, calendar: Calendar = .current
    ) -> (done: Int, total: Int) {
        let forDay = tasksForDay(tasks, day: day, calendar: calendar)
        return (forDay.filter { $0.stage == .done }.count, forDay.count)
    }

    /// Merges today's tasks and events into one chronological agenda: timed
    /// items ascending by time, then untimed tasks and all-day events (in
    /// their original relative order). Tasks reuse `tasksForDay`'s day
    /// filtering; events are today's events with no additional filtering —
    /// they have no done state to filter on.
    public static func agenda(
        tasks: [MustardTask], events: [CalendarEvent], day: Date, calendar: Calendar = .current
    ) -> [AgendaItem] {
        let taskItems = tasksForDay(tasks, day: day, calendar: calendar).map { task in
            AgendaItem(
                id: "task:\(task.uid)",
                kind: .task(task),
                time: task.isTimed ? task.scheduledAt : nil,
                title: task.title,
                isDone: task.stage == .done,
                tagLabel: task.list?.area?.name,
                tagColorHex: task.list?.area?.colorHex,
                joinURL: nil
            )
        }
        let eventItems = events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .map { event -> AgendaItem in
                AgendaItem(
                    id: "event:\(event.externalId.isEmpty ? event.title : event.externalId)",
                    kind: .event(event),
                    time: event.isAllDay ? nil : event.start,
                    title: event.title,
                    isDone: false,
                    tagLabel: nil,
                    tagColorHex: nil,
                    joinURL: event.joinURL
                )
            }
        let all = taskItems + eventItems
        let timed = all
            .filter { $0.time != nil }
            .sorted { lhs, rhs in
                guard let l = lhs.time, let r = rhs.time else { return false }
                return l < r
            }
        let untimed = all.filter { $0.time == nil }
        return timed + untimed
    }

    /// Next open, scheduled tasks starting after `after`, soonest first (for the hover panel).
    public static func upcoming(
        _ tasks: [MustardTask], after: Date, limit: Int = 3
    ) -> [MustardTask] {
        tasks
            .filter { task in
                guard task.stage.isOpen, !task.isBlocked, let when = task.scheduledAt else { return false }
                return when > after
            }
            .sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Move open tasks scheduled before `today` onto `today`, keeping their time-of-day.
    public static func carryForward(
        _ tasks: [MustardTask], to today: Date, calendar: Calendar = .current
    ) {
        let startOfToday = calendar.startOfDay(for: today)
        for task in tasks {
            guard task.stage.isOpen, let when = task.scheduledAt,
                  when < startOfToday else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: when)
            task.scheduledAt = calendar.date(
                bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0,
                of: startOfToday
            )
            // A scheduled task must not sit in the Inbox (BAK-246) — a carry-forward of
            // a stranded inbox row would otherwise keep it stranded on the new day.
            PersonalBoard.normalizePlacement(task)
            // Record what rolled over — the morning ritual keys its rollover step off
            // this stamp. Only tasks actually moved (past the guard above) get stamped.
            task.carriedForwardAt = startOfToday
        }
    }
}
