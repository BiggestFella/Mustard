import Foundation

/// Area filter for the board. `personal` matches the Errands/Reading lists.
public enum BoardArea: Equatable {
    case all, area(String), personal
}

/// Grouping logic for the personal Kanban board (owner == me).
public enum PersonalBoard {
    /// How many completed tasks the Done column keeps visible. The rest collapse
    /// into a "+N older" footer so the board can't grow unbounded as done tasks
    /// accumulate — a count cap, not a date window, so it bounds the column
    /// regardless of how completion timestamps cluster.
    public static let doneColumnLimit = 15

    // MARK: - Stage-based board (BAK-76)
    // Owner-segmented API keyed on `TaskStage` (the source of truth). The legacy
    // `status`-based functions were retired in BAK-80.

    /// Columns shown for a given owner view.
    public static func columns(for view: BoardOwnerView) -> [TaskStage] { view.columns }

    /// The gate columns shown when the board is focused to the review queue
    /// ("N waiting on you" → Exit review queue, BAK-101).
    public static let gateStages: [TaskStage] = TaskStage.allCases.filter { $0.isGate }

    /// Board search (BAK-134): case-insensitive title filter; empty query → unchanged.
    public static func filterBySearch(_ tasks: [MustardTask], query: String) -> [MustardTask] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    /// Whether an empty column should auto-collapse to a thin strip (BAK-102): only
    /// in the Everyone lens, never while review-focused, and not if the user has
    /// manually expanded it. Mine/Agent lenses keep empty columns full-width.
    public static func shouldCollapseEmpty(view: BoardOwnerView, isEmpty: Bool,
                                           expanded: Bool, reviewFocus: Bool) -> Bool {
        view == .everyone && !reviewFocus && isEmpty && !expanded
    }

    /// Tasks in a stage within the current owner + area scope, oldest first
    /// (done by most-recently-completed).
    public static func tasks(_ all: [MustardTask], in stage: TaskStage,
                             view: BoardOwnerView, area: BoardArea) -> [MustardTask] {
        all.filter { $0.stage == stage && ownerOK($0, view) && areaOK($0, area) }
            .sorted { sortKey($0) < sortKey($1) }
    }

    /// Items needing you within the current scope.
    public static func waitingCount(_ all: [MustardTask], view: BoardOwnerView, area: BoardArea) -> Int {
        all.filter { needsHuman($0) && ownerOK($0, view) && areaOK($0, area) }.count
    }

    /// Unfiltered agent attention badge (sidebar).
    public static func agentBadge(_ all: [MustardTask]) -> Int {
        all.filter(needsHuman).count
    }

    /// Done beyond the visible limit, within scope — the "+N older" remainder.
    public static func olderDoneCount(_ all: [MustardTask], view: BoardOwnerView,
                                      area: BoardArea, limit: Int = doneColumnLimit) -> Int {
        max(0, tasks(all, in: .done, view: view, area: area).count - limit)
    }

    /// Apply a column move by stage: set stage, keep completedAt consistent with done.
    public static func move(_ task: MustardTask, to stage: TaskStage, now: Date = .now) {
        if stage == .done { task.markDone(now: now) }
        else { task.stage = stage; task.completedAt = nil }
        if MeetingTaskSource.requiresAgentApproval(task.source) {
            if stage == .queued { task.agentApprovalGranted = true }
            if stage == .forAgent || stage == .needsApproval { task.agentApprovalGranted = false }
        }
    }

    /// Target stage when the human approves a gate (BAK-100). Agent-owned
    /// needsApproval tasks always queue for execution; personal non-gated tasks
    /// advance straight to output review. Gated actions always queue regardless of
    /// owner.
    /// needsReview → done. Nil when the task isn't on a gate stage. Reject/Discard
    /// (deletion) and the reverse transitions (Hold→needsApproval, Request changes→
    /// queued) are handled by the caller via `move`/delete.
    public static func approveTarget(for task: MustardTask) -> TaskStage? {
        switch task.stage {
        case .needsApproval: return task.isGated || task.owner == .agent ? .queued : .needsReview
        case .needsReview: return .done
        default: return nil
        }
    }

    /// The stages that mean "the agent owns this" — the hand-off pipeline lanes. Single
    /// source of truth: the board drop guard, the detail-sheet stage picker, and the
    /// quick-add composer all classify against this, so a task can never enter a lane
    /// through one path that another path would have gated.
    public static let agentLaneStages: Set<TaskStage> = [
        .forAgent, .needsApproval, .queued, .inProgress, .needsInput, .needsReview,
    ]

    /// Whether `stage` is one of the agent hand-off lanes.
    public static func isAgentLane(_ stage: TaskStage) -> Bool { agentLaneStages.contains(stage) }

    /// Whether a task may be handed to the agent (For Agent / Queued). Requires a
    /// client area: the bridge export filters by area, so an area-less hand-off would
    /// silently never route (BAK-90). The single gate the views + `delegate` check.
    public static func canHandOffToAgent(_ task: MustardTask) -> Bool {
        task.list?.area != nil
    }

    /// Where a *brand-new* quick-add task should land when typed into a column, given the
    /// board's current area scope. A new task has no area yet, so it can never satisfy
    /// `canHandOffToAgent` on its own — creating it directly in an agent lane would strand
    /// it (area-less → the bridge export silently drops it → "waiting for agent" forever).
    /// So: non-agent columns keep the column's stage (owner me); an agent lane inherits the
    /// board's scoped client area for a real hand-off (owner agent); an agent lane with no
    /// single client area to inherit (All / personal) is safely downgraded to Planned and
    /// flagged so the caller can hint the user to pick an area first.
    public struct NewTaskPlacement: Equatable {
        public let stage: TaskStage
        public let owner: TaskOwner
        /// Caller must attach a list belonging to the board's scoped area (real hand-off).
        public let attachArea: Bool
        /// An agent-lane request was downgraded to Planned; caller should surface a hint.
        public let blockedHandOff: Bool
        public init(stage: TaskStage, owner: TaskOwner, attachArea: Bool, blockedHandOff: Bool) {
            self.stage = stage; self.owner = owner
            self.attachArea = attachArea; self.blockedHandOff = blockedHandOff
        }
    }

    public static func newTaskPlacement(inColumn column: TaskStage, boardArea: BoardArea) -> NewTaskPlacement {
        guard isAgentLane(column) else {
            return NewTaskPlacement(stage: column, owner: .me, attachArea: false, blockedHandOff: false)
        }
        if case .area = boardArea {
            return NewTaskPlacement(stage: column, owner: .agent, attachArea: true, blockedHandOff: false)
        }
        // Agent lane but no single client area to inherit → don't strand it.
        return NewTaskPlacement(stage: .planned, owner: .me, attachArea: false, blockedHandOff: true)
    }

    /// Enforce the scheduled-placement invariant (BAK-246): a task carrying a
    /// `scheduledAt` must never sit in `.inbox` (Inbox = untriaged only). A scheduled
    /// task still in the inbox moves to `.scheduled` when anchored to a specific time
    /// (`isTimed`) and `.planned` (planned for the day) otherwise. Tasks already past
    /// the inbox — agent lanes, in-progress, blocked, done — keep their stage, and
    /// unscheduled tasks are left untouched. Pure (mutates only the passed task's
    /// stage) and idempotent, so it is safe to call at every site that writes
    /// `scheduledAt`: this is the single source of truth those sites used to open-code
    /// (inconsistently, ignoring `isTimed`) or skip entirely.
    public static func normalizePlacement(_ task: MustardTask) {
        guard task.scheduledAt != nil, task.stage == .inbox else { return }
        task.stage = task.isTimed ? .scheduled : .planned
    }

    /// Card owner toggle: to agent → forAgent; to me → planned; done keeps its stage.
    public static func reassign(_ task: MustardTask, to owner: TaskOwner) {
        guard task.owner != owner else { return }
        task.owner = owner
        if task.stage != .done { task.stage = owner == .agent ? .forAgent : .planned }
    }

    private static func ownerOK(_ t: MustardTask, _ view: BoardOwnerView) -> Bool {
        switch view {
        case .everyone: return true
        case .mine: return t.owner == .me
        case .agent: return t.owner == .agent
        }
    }

    private static func needsHuman(_ task: MustardTask) -> Bool {
        task.stage.isGate
    }

    /// Public area predicate — mobile Week (BAK-116) scopes its day-strip capacity,
    /// rail, and selected-day list to the shared area filter using the board's own
    /// tested rule (no duplicated logic).
    public static func matchesArea(_ task: MustardTask, _ area: BoardArea) -> Bool {
        areaOK(task, area)
    }

    private static func areaOK(_ t: MustardTask, _ area: BoardArea) -> Bool {
        switch area {
        case .all: return true
        case .area(let name): return t.list?.area?.name == name
        case .personal:
            let n = t.list?.area?.name
            return n == "Errands" || n == "Reading"
        }
    }

    /// Done sorts by completedAt desc; everything else by createdAt asc.
    private static func sortKey(_ t: MustardTask) -> Double {
        t.stage == .done ? -(t.completedAt ?? .distantPast).timeIntervalSince1970
                         : t.createdAt.timeIntervalSince1970
    }
}
