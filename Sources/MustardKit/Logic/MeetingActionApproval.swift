import Foundation
import SwiftData

/// Approval-gated conversion of a meeting proposal into a task (meeting
/// recorder Task 8, BAK-300). Every proposed action item requires Leon's
/// explicit approve; approval creates exactly one LOCAL task — Inbox by
/// default, or Planned/Scheduled when a date is set (BAK-246) — never an
/// outward action, never agent ownership.
public enum MeetingActionApproval {
    /// Approve, applying any reviewed edits. Idempotent by proposal uid: a
    /// second approval returns the already-created task.
    @MainActor
    @discardableResult
    public static func approve(
        _ proposal: MeetingActionProposal,
        title: String? = nil,
        scheduledFor: Date? = nil,
        areaName: String? = nil,
        context: ModelContext
    ) -> MustardTask {
        // Idempotency: one task per proposal, anchored on the proposal uid.
        if proposal.state == .approved, let existing = proposal.createdTask {
            return existing
        }
        let task = MustardTask(title: title ?? proposal.title)
        task.source = "meeting-recording"
        task.sourceContext = proposal.meeting?.title ?? "Meeting recording"
        task.originKey = proposal.uid
        if let notes = proposal.notes { task.notes = notes }
        if let date = scheduledFor ?? proposal.scheduledFor {
            task.scheduledAt = date
            task.isTimed = false
            PersonalBoard.normalizePlacement(task)
        }
        context.insert(task)
        if let areaName = areaName ?? proposal.areaName, !areaName.isEmpty {
            task.stampArea(named: areaName, in: context)
        }
        proposal.state = .approved
        proposal.createdTask = task
        try? context.save()
        return task
    }

    /// Reject: the proposal keeps its evidence for the record, and no task
    /// ever exists.
    @MainActor
    public static func reject(_ proposal: MeetingActionProposal, context: ModelContext) {
        guard proposal.state == .pending else { return }
        proposal.state = .rejected
        try? context.save()
    }
}

// MARK: - Area stamping (shared: capture coordinator, quick editor, approval)

extension MustardTask {
    /// Find-or-create the named area + its list and stamp this task — the
    /// sibling of `AgentService.ensureArea(_:named:)` for callers whose area
    /// name was already validated against an allowed list. Passing
    /// `overriding: true` re-stamps a task that already has a list (an
    /// explicit user pick); the default never overrides.
    @MainActor
    func stampArea(named areaName: String, in context: ModelContext, overriding: Bool = false) {
        guard overriding || list == nil else { return }
        guard list?.area?.name != areaName else { return }
        let area = (try? context.fetch(FetchDescriptor<Area>()))?.first { $0.name == areaName }
            ?? { let a = Area(name: areaName); context.insert(a); return a }()
        if let existing = (try? context.fetch(FetchDescriptor<TaskList>()))?.first(where: { $0.area?.name == areaName }) {
            list = existing
        } else {
            let created = TaskList(name: areaName, area: area)
            context.insert(created)
            list = created
        }
    }
}
