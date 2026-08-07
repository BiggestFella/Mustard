import Foundation

/// Pure content + mutation rules for the four-step morning ritual (spec
/// 2026-07-06). Views render these and dispatch; all decisions live here.
public enum RitualPlanner {
    public static let focusLimit = 3

    /// Step 1 — tasks the silent carry-forward moved onto `day` (open only).
    ///
    /// NOTE (Task 1 review): a task carried this morning then pushed to tomorrow
    /// via the wizard keeps today's `carriedForwardAt` stamp, so it stays in this
    /// list — deliberate, so the wizard row can show its chosen ("Tomorrow") state
    /// rather than vanishing mid-triage.
    public static func rollover(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> [MustardTask] {
        tasks.filter { task in
            guard task.stage.isOpen, let stamp = task.carriedForwardAt else { return false }
            return calendar.isDate(stamp, inSameDayAs: day)
        }
    }

    /// Step 1 mutation — push to the same time tomorrow.
    public static func pushToTomorrow(_ task: MustardTask, calendar: Calendar = .current) {
        guard let when = task.scheduledAt else { return }
        task.scheduledAt = calendar.date(byAdding: .day, value: 1, to: when)
        PersonalBoard.normalizePlacement(task)
    }

    /// Step 1 mutation — back to the unscheduled inbox. Leaves the carry-forward
    /// stamp so the row keeps its rollover context for the rest of the wizard.
    public static func sendToInbox(_ task: MustardTask) {
        task.scheduledAt = nil
    }

    /// Step 3 — unscheduled open tasks (the pick pool). Excludes agent-owned.
    public static func pickCandidates(_ tasks: [MustardTask]) -> [MustardTask] {
        tasks.filter { $0.scheduledAt == nil && $0.stage.isOpen && $0.owner == .me }
    }

    /// Step 3 — today's already-planned open tasks (the removable set shown with a
    /// minus above the pick pool). Restricted to `owner == .me` deliberately:
    /// un-planning agent-owned tasks from the wizard would interfere with the
    /// agent's own scheduling. The asymmetry with `focusCandidates` (which is
    /// owner-agnostic) is intentional — starring agent work as YOUR focus is
    /// legitimate watching; un-planning it is not.
    public static func plannedToday(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> [MustardTask] {
        tasks.filter { task in
            guard task.stage.isOpen, task.owner == .me, let when = task.scheduledAt else { return false }
            return calendar.isDate(when, inSameDayAs: day)
        }
    }

    /// Step 3 mutation — plan onto `day`, untimed.
    public static func planToday(_ task: MustardTask, day: Date, calendar: Calendar = .current) {
        task.scheduledAt = calendar.startOfDay(for: day)
        task.isTimed = false
        PersonalBoard.normalizePlacement(task)
    }

    /// Step 3 capacity line — WeekPlanner reuse; nil label when nothing planned.
    public static func capacityLine(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> String? {
        let openPlanned = tasks.contains { t in
            guard t.stage.isOpen, let when = t.scheduledAt else { return false }
            return calendar.isDate(when, inSameDayAs: day)
        }
        guard openPlanned else { return nil }
        let minutes = WeekPlanner.capacityMinutes(tasks, on: day, calendar: calendar)
        return "\(WeekPlanner.capacityLabel(minutes: minutes)) planned"
    }

    /// Today's chronological timeline (BAK-247): the day's scheduled tasks minus any
    /// pinned in the FOCUS section (starred as focus for `day`). A focus-starred task
    /// shows exactly once — as a pin in FOCUS — instead of being duplicated in the
    /// timeline below it. Shared so any surface with a FOCUS section dedups identically.
    public static func timeline(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> [MustardTask] {
        let focusUIDs = Set(focused(tasks, day: day, calendar: calendar).map(\.uid))
        return DayPlanner.tasksForDay(tasks, day: day, calendar: calendar)
            .filter { !focusUIDs.contains($0.uid) }
    }

    /// Step 4 — today's open planned tasks (star candidates).
    public static func focusCandidates(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> [MustardTask] {
        DayPlanner.tasksForDay(tasks, day: day, calendar: calendar).filter { $0.stage.isOpen }
    }

    /// Step 4 — the currently-starred tasks for `day`.
    public static func focused(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> [MustardTask] {
        tasks.filter { task in
            guard let star = task.focusOnDay else { return false }
            return calendar.isDate(star, inSameDayAs: day)
        }
    }

    /// Toggle star; returns false (and does nothing) when adding would exceed focusLimit.
    /// The cap counts OPEN stars only — a completed star keeps its focusOnDay (so
    /// Today's FOCUS pinning can still show it) but frees its slot; otherwise the
    /// wizard (whose candidates are open-only) could never un-star it to make room
    /// for a replacement.
    @discardableResult
    public static func toggleFocus(_ task: MustardTask, in all: [MustardTask], day: Date, calendar: Calendar = .current) -> Bool {
        let isStarred = task.focusOnDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        if isStarred {
            // Un-star is always allowed.
            task.focusOnDay = nil
            return true
        }
        let openStars = focused(all, day: day, calendar: calendar).filter { $0.stage.isOpen }.count
        guard openStars < focusLimit else { return false }
        task.focusOnDay = calendar.startOfDay(for: day)
        return true
    }

    /// Notch focus slot — first open focus task's title (sorted by scheduledAt, then title), nil when none.
    public static func focusTitle(_ tasks: [MustardTask], day: Date, calendar: Calendar = .current) -> String? {
        focused(tasks, day: day, calendar: calendar)
            .filter { $0.stage.isOpen }
            .sorted {
                let l = $0.scheduledAt ?? .distantFuture
                let r = $1.scheduledAt ?? .distantFuture
                return l != r ? l < r : $0.title < $1.title
            }
            .first?.title
    }
}
