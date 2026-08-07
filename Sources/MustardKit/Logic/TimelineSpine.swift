import Foundation

/// One day on the Today spine: its start-of-day date, a display label, and the merged
/// chronological agenda (tasks + events) for that day, reusing `DayPlanner.agenda`.
public struct SpineDay: Identifiable {
    public let day: Date
    public let label: SpineDayLabel
    public let items: [AgendaItem]
    public var id: Date { day }
}

/// How a spine day's header reads. `.other` carries the date so the VIEW does the
/// locale/timezone formatting — the builder stays timezone-agnostic and testable.
public enum SpineDayLabel: Equatable {
    case today
    case tomorrow
    case other(Date)
}

/// Pure builder for the forward-flowing Today spine. No SwiftData, no views.
public enum TimelineSpine {
    /// Today (always present, even empty — it carries Today's empty state) plus each of
    /// the next `horizonDays` days that hold at least one item. Each day is a merged
    /// tasks+events agenda. FOCUS-pinned tasks are excluded from TODAY only, so a pinned
    /// task shows once in the FOCUS band above the spine (mirrors `RitualPlanner.timeline`
    /// / BAK-247).
    public static func build(
        tasks: [MustardTask],
        events: [CalendarEvent],
        reference: Date,
        horizonDays: Int = 7,
        calendar: Calendar = .current
    ) -> [SpineDay] {
        let startOfToday = calendar.startOfDay(for: reference)
        let focusUIDs = Set(
            RitualPlanner.focused(tasks, day: startOfToday, calendar: calendar).map(\.uid)
        )

        var days: [SpineDay] = []
        for offset in 0...max(0, horizonDays) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday)
            else { continue }

            var items = DayPlanner.agenda(tasks: tasks, events: events, day: day, calendar: calendar)
            if offset == 0 {
                items = items.filter { item in
                    if case let .task(t) = item.kind { return !focusUIDs.contains(t.uid) }
                    return true
                }
            }
            // Today always renders; later days only when they carry something.
            guard offset == 0 || !items.isEmpty else { continue }
            days.append(SpineDay(day: day, label: label(offset: offset, day: day), items: items))
        }
        return days
    }

    static func label(offset: Int, day: Date) -> SpineDayLabel {
        switch offset {
        case 0: return .today
        case 1: return .tomorrow
        default: return .other(day)
        }
    }

    /// Whether a timed item lies before `reference` — used to dim TODAY's elapsed items.
    /// Untimed items are never past.
    public static func isPast(_ item: AgendaItem, relativeTo reference: Date) -> Bool {
        guard let time = item.time else { return false }
        return time < reference
    }
}
