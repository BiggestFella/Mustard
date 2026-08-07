import Foundation
import SwiftData

@Model
public final class MustardTask {
    /// Stable id for drag-and-drop transfer (PersistentIdentifier isn't Transferable).
    public var uid: String = UUID().uuidString
    public var title: String = ""
    public var notes: String = ""
    public var statusRaw: String = TaskStatus.inbox.rawValue
    public var ownerRaw: String = TaskOwner.me.rawValue
    public var scheduledAt: Date?
    /// When scheduled: `false` = planned for the day (flows in the week list);
    /// `true` = anchored to a specific time on the week's time axis.
    public var isTimed: Bool = false
    public var estimateMinutes: Int = 30
    public var createdAt: Date = Date.now
    public var completedAt: Date?
    /// Stamped by DayPlanner.carryForward when it moves this task onto a new day —
    /// lets the morning ritual show exactly what rolled over (spec 2026-07-06),
    /// without changing when/how carry-forward moves tasks. Optional → CloudKit-safe.
    public var carriedForwardAt: Date?
    /// startOfDay this task is starred as a focus intention for. "Starred today" =
    /// focusOnDay is today, so stars expire naturally at midnight — no cleanup pass.
    public var focusOnDay: Date?
    public var list: TaskList?
    public var priorityRaw: String = TaskPriority.normal.rawValue
    public var dueAt: Date?
    public var recurrenceRaw: String?
    public var tags: [String] = []
    public var blockedReason: String = ""
    public var recurredFrom: String?
    public var autoCompleted: Bool = false
    public var parent: MustardTask?
    @Relationship(deleteRule: .nullify, inverse: \MustardTask.parent)
    public var subtasks: [MustardTask]? = []
    /// The agent recommendation produced when this task was delegated ("Ask agent to
    /// do this"). Nullify: deleting the task clears the link but keeps the rec (and its
    /// output history). Optional → CloudKit-safe default (ADR-0001).
    @Relationship(deleteRule: .nullify, inverse: \Recommendation.task)
    public var delegation: Recommendation?
    @Relationship(deleteRule: .cascade, inverse: \AgentRun.task)
    public var agentRun: AgentRun?
    /// Another task that must finish before this one can proceed (the detail/form
    /// "Blocked by"). Optional, no inverse → CloudKit-safe (ADR-0001); nullify on
    /// delete so removing the blocker just clears the dependency.
    @Relationship(deleteRule: .nullify)
    public var blockedByTask: MustardTask?

    // Provenance — set when a task is harvested from an external source (e.g. a
    // meeting note). All defaulted/optional so the CloudKit schema stays additive.
    /// `"manual"` for user-created, `"meeting"` for harvested meeting tasks.
    public var source: String = "manual"
    /// Source location — for meeting tasks, the note path relative to the vault root.
    public var sourceURL: String?
    /// Human subtitle for the row (e.g. the meeting title + date).
    public var sourceContext: String = ""
    /// Stable identity from `MeetingTaskParser.originKey` — dedup + line locator.
    public var originKey: String?

    // Voice capture lifecycle (F25, ADR-0011). All optional/defaulted so the CloudKit
    // schema stays additive (ADR-0001); nil/0 on every non-capture task.
    /// `raw` = awaiting the cleanup pass, `cleaned` = pass applied, `failed` = pass
    /// gave up (task stays usable with its raw title). Nil for non-capture tasks.
    public var captureStateRaw: String?
    /// The verbatim speech transcript, preserved so cleanup is never destructive.
    public var captureTranscript: String?
    /// Failed cleanup attempts so far (drives the 60/300/900s backoff ladder).
    public var captureAttempts: Int = 0
    /// Cleanup backoff window — the queue skips this task until this passes.
    public var captureNextAttemptAt: Date?

    // Board stage model (BAK-74). `stage` supersedes `status`; `statusRaw` is kept
    // only so existing stores decode and `BoardMigration` can backfill `stage`.
    public var stageRaw: String = TaskStage.inbox.rawValue
    /// True once `stage` has been backfilled from legacy `statusRaw` (one-time).
    public var migratedStage: Bool = false
    /// Outward/connector action this task performs when agent-bound — drives gating
    /// and the headless-vs-connector route. Nil for ordinary personal tasks.
    public var actionTypeRaw: String?
    /// Agent confidence (0…1) shown on Needs Approval / proposed cards.
    public var confidence: Double?
    /// Links surfaced on a Needs Review card (Shortcut / Jira / draft).
    public var links: [TaskLink] = []

    public var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .inbox }
        set { statusRaw = newValue.rawValue }
    }

    public var stage: TaskStage {
        get { TaskStage(rawValue: stageRaw) ?? .inbox }
        set { stageRaw = newValue.rawValue }
    }

    public var captureState: CaptureState? {
        get { captureStateRaw.flatMap(CaptureState.init(rawValue:)) }
        set { captureStateRaw = newValue?.rawValue }
    }

    public var actionType: RecommendationAction? {
        get { actionTypeRaw.flatMap(RecommendationAction.init(rawValue:)) }
        set { actionTypeRaw = newValue?.rawValue }
    }

    /// Outward/connector actions are always gated (reuse the recommendation policy).
    public var isGated: Bool { actionType?.isGated ?? false }

    /// Agent-surfaced and still in the inbox, awaiting your triage — drives the
    /// "✦ Proposed" pill (handoff: agent-proposed tasks land in Inbox flagged Proposed).
    public var isProposed: Bool { owner == .agent && stage == .inbox }

    public var owner: TaskOwner {
        get { TaskOwner(rawValue: ownerRaw) ?? .me }
        set { ownerRaw = newValue.rawValue }
    }

    public var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    public var recurrence: Recurrence? {
        get { recurrenceRaw.flatMap(Recurrence.init(rawValue:)) }
        set { recurrenceRaw = newValue?.rawValue }
    }

    public var isBlocked: Bool {
        // Blocked by an unfinished dependency, or by a free-text reason.
        if let blocker = blockedByTask, blocker.stage != .done { return true }
        return !blockedReason.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// (completed, total) over direct subtasks — drives the "0/1" header.
    public var subtaskProgress: (done: Int, total: Int) {
        let subs = subtasks ?? []
        return (subs.filter { $0.stage == .done }.count, subs.count)
    }

    public init(title: String = "", owner: TaskOwner = .me, scheduledAt: Date? = nil) {
        self.title = title
        self.ownerRaw = owner.rawValue
        self.scheduledAt = scheduledAt
        self.createdAt = .now
        // Tasks created in code are born on the stage model — they carry no legacy
        // status to migrate. Marking them migrated keeps the launch backfill (which
        // derives stage from `statusRaw`) from ever clobbering their stage. Only rows
        // decoded from a pre-stage store (default false) get backfilled, once each.
        self.migratedStage = true
    }

    /// Mark done, stamping completion time, and cascade-complete open subtasks
    /// (recursively). Idempotent. Subtasks completed this way are flagged
    /// `autoCompleted`; the task you call this on is not.
    public func markDone(now: Date = .now) {
        status = .done
        stage = .done
        completedAt = now
        for child in subtasks ?? [] where child.stage.isOpen {
            child.autoCompleted = true
            child.markDone(now: now)
        }
    }
}
