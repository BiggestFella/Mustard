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
        tasks.filter {
            $0.stage == .needsApproval || $0.stage == .needsInput || $0.stage == .needsReview
        }.count
    }

    /// The two attention groups for the unified Agent Console queue: questions (Needs You)
    /// and outputs (Needs Review), each oldest-first so the longest-waiting item leads.
    public struct AgentAttention {
        public let questions: [MustardTask]
        public let reviews: [MustardTask]
        /// All three gate stages (needsApproval ∪ needsInput ∪ needsReview) in one
        /// oldest-first list — the console's "In flight · needs you" tier (F27).
        public let inFlight: [MustardTask]
    }

    public static func attention(_ tasks: [MustardTask]) -> AgentAttention {
        // Oldest-first, with a uid tiebreak so equal timestamps order deterministically
        // (Swift's sort isn't stable) — matches AgentRun.orderedMessages / AgentTaskQueue.
        func precedes(_ a: MustardTask, _ b: MustardTask) -> Bool {
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.uid < b.uid
        }
        let gateStages: Set<TaskStage> = [.needsApproval, .needsInput, .needsReview]
        return AgentAttention(
            questions: tasks.filter { $0.stage == .needsInput }.sorted(by: precedes),
            reviews: tasks.filter { $0.stage == .needsReview }.sorted(by: precedes),
            inFlight: tasks.filter { gateStages.contains($0.stage) }.sorted(by: precedes)
        )
    }

    /// The console gate row's primary button for a stage: its label, and whether it
    /// advances in one click (Approve/Accept, via PersonalBoard.approveTarget) or must
    /// open the conversation (Answer — replying needs typing). Nil for non-gate stages.
    public static func gateAction(for stage: TaskStage) -> (label: String, oneClick: Bool)? {
        switch stage {
        case .needsApproval: return ("Approve", true)
        case .needsInput: return ("Answer", false)
        case .needsReview: return ("Accept", true)
        default: return nil
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
