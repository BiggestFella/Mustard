import Foundation

/// What's waiting on the human from the agent right now — the count behind the
/// sidebar badge, the co-pilot dock, and Today's "Agent has N things for you" nudge
/// (BAK-104). Pure + tested; respects snooze/ignore via `RecommendationQueue.pending`.
public enum AgentInbox {
    /// Pending (un-snoozed, non-ignored) recommendations + tasks needing input or review.
    public static func waitingCount(
        recommendations: [Recommendation], tasks: [MustardTask], now: Date = .now
    ) -> Int {
        pendingRecCount(recommendations, now: now) + attentionTaskCount(tasks)
    }

    /// Pending (un-snoozed, non-ignored) recommendations awaiting triage.
    public static func pendingRecCount(_ recommendations: [Recommendation], now: Date = .now) -> Int {
        RecommendationQueue.pending(recommendations, now: now).count
    }

    /// Agent tasks awaiting your approval, answer, or output review (all three gate
    /// stages) — matches PersonalBoard.waitingCount/needsHuman (F27 count unification).
    public static func attentionTaskCount(_ tasks: [MustardTask]) -> Int {
        tasks.filter { isHumanAttention($0) }.count
    }

    /// The single attention bucket for the console's "In flight · needs you" tier:
    /// all three gate stages (needsApproval ∪ needsInput ∪ needsReview), oldest-first.
    public struct AgentAttention {
        public let inFlight: [MustardTask]
        public let questions: [MustardTask]
        public let reviews: [MustardTask]
        public let background: [MustardTask]
    }

    public static func attention(_ tasks: [MustardTask]) -> AgentAttention {
        // Oldest-first, with a uid tiebreak so equal timestamps order deterministically
        // (Swift's sort isn't stable) — matches AgentRun.orderedMessages / AgentTaskQueue.
        func precedes(_ a: MustardTask, _ b: MustardTask) -> Bool {
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.uid < b.uid
        }
        let inFlight = tasks.filter { $0.stage.isGate && isHumanAttention($0) }.sorted(by: precedes)
        let questions = tasks.filter { $0.stage == .needsInput && isHumanAttention($0) }.sorted(by: precedes)
        let reviews = tasks.filter { $0.stage == .needsReview && isHumanAttention($0) }.sorted(by: precedes)
        let background = tasks.filter {
            $0.stage.isGate
                && CodeHeroesDecisionPolicy.isProjection($0)
                && !isHumanAttention($0)
        }.sorted(by: precedes)
        return AgentAttention(inFlight: inFlight, questions: questions, reviews: reviews, background: background)
    }

    /// A projection is actionable only when the source queue explicitly marks it
    /// as requiring a human decision or action. Background memory-maintenance and
    /// source-health projections remain visible in the console without inflating
    /// the global "Needs You" count.
    public static func isHumanAttention(_ task: MustardTask) -> Bool {
        guard task.stage.isGate else { return false }
        guard CodeHeroesDecisionPolicy.isProjection(task) else { return true }
        return task.tags.contains("human-action")
    }

    /// The verb pair a gate offers. Single source of truth for the console row, the
    /// task detail sheet and the board card, so the same function can never wear
    /// three different labels (it wore five before 2026-08-21: Do/Don't on the row,
    /// Approve & run/Deny/Delete task in the sheet, two of them the same call).
    ///
    /// `oneClick` is false when the primary needs the conversation open (Answer —
    /// replying means typing). `secondary` is the destructive drop, nil on stages
    /// that have none.
    public struct GateChoice: Equatable, Sendable {
        public let primary: String
        public let secondary: String?
        public let oneClick: Bool
    }

    /// True when the gate decision is "is this a real task?" rather than "should the
    /// agent run this?" — a ledger-harvested meeting task that is mine. Those arrive
    /// unasked from a meeting note, so triage classifies them; execution is a later,
    /// separate hand-off (`AgentService.delegate`). Once handed over the row is
    /// agent-owned again and the gate goes back to being an execute approval.
    public static func isExistenceTriage(_ task: MustardTask) -> Bool {
        MeetingTaskSource.requiresAgentApproval(task.source) && task.owner == .me
    }

    /// The gate's verbs for a task. Nil for non-gate stages. Enumerates the gate
    /// stages (`TaskStage.isGate`) — keep in sync if a gate stage is added, or a new
    /// `.gate` stage will surface in `inFlight` with no action button.
    public static func gate(for task: MustardTask) -> GateChoice? {
        switch task.stage {
        case .needsApproval:
            if isExistenceTriage(task) {
                return GateChoice(primary: "Keep", secondary: "Delete", oneClick: true)
            }
            let approve = task.isGated || task.owner == .agent ? "Approve & run" : "Approve"
            return GateChoice(primary: approve, secondary: "Deny", oneClick: true)
        case .needsInput:
            return GateChoice(primary: "Answer", secondary: nil, oneClick: false)
        case .needsReview:
            return GateChoice(primary: "Accept", secondary: "Discard", oneClick: true)
        default:
            return nil
        }
    }

    /// Co-pilot dock text (BAK-106): "{N} recommendation(s) and {M} item(s) waiting
    /// on you", or "All clear — nothing waiting on you" when both are zero.
    public static func dockText(recs: Int, items: Int) -> String {
        guard recs > 0 || items > 0 else { return "All clear — nothing waiting on you" }
        var parts: [String] = []
        if recs > 0 { parts.append("\(recs) recommendation\(recs == 1 ? "" : "s")") }
        if items > 0 { parts.append("\(items) item\(items == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + " waiting on you"
    }
}
