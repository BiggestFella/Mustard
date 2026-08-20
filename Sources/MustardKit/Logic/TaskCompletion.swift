import Foundation
import SwiftData

/// The single choke-point for complete / reopen: cascade-complete subtasks
/// (via markDone) and, if the task recurs, insert a fresh next instance. Used by
/// every completion path (Today, Week, Lists, Notch, the detail sheet, Board
/// drag-to-Done) so recurrence fires uniformly. Not pure (needs a context); its
/// pieces — markDone and RecurrenceEngine.nextInstance — are unit-tested
/// individually.
public enum TaskCompletion {
    public static func complete(_ task: MustardTask, in context: ModelContext, now: Date = .now) {
        let next = RecurrenceEngine.nextInstance(of: task, now: now)
        task.markDone(now: now)
        if let next { context.insert(next) }
    }

    /// Reopen a completed task. Clears the done stamp and the legacy `status`
    /// column so a later launch backfill cannot re-complete it.
    public static func reopen(_ task: MustardTask) {
        task.stage = .planned
        task.completedAt = nil
        task.autoCompleted = false
        if task.status == .done { task.status = .planned }
    }

    /// Checkbox / row-toggle: complete (with recurrence) or reopen.
    public static func toggle(_ task: MustardTask, in context: ModelContext, now: Date = .now) {
        if task.stage == .done {
            reopen(task)
        } else {
            complete(task, in: context, now: now)
        }
    }
}
