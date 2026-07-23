import Foundation

/// The single lifecycle field for a board task. Supersedes `TaskStatus` and the
/// previously-derived `DelegationPhase`: one task, one stage, one owner.
public enum TaskStage: String, Codable, CaseIterable, Identifiable {
    case inbox, planned, scheduled, forAgent, needsApproval,
         queued, inProgress, needsInput, needsReview, blocked, done
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inbox: "Inbox"
        case .planned: "Planned"
        case .scheduled: "Scheduled"
        case .forAgent: "For Agent"
        case .needsApproval: "Needs Approval"
        case .queued: "Approved · Queued"
        case .inProgress: "In Progress"
        case .needsInput: "Needs You"
        case .needsReview: "Needs Review"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    public var subLabel: String? {
        switch self {
        case .forAgent: "agent picks up & preps"
        case .needsApproval: "approve before it runs"
        case .needsInput: "answer the agent"
        case .needsReview: "check the output"
        default: nil
        }
    }

    public var kind: TaskColumnKind {
        switch self {
        case .forAgent: .handoff
        case .needsApproval, .needsInput, .needsReview: .gate
        case .queued: .agent
        case .blocked: .warn
        case .done: .done
        default: .standard
        }
    }

    /// Open == still actionable (excludes done).
    public var isOpen: Bool { self != .done }

    /// True for the three "needs a human decision" gate stages (needsApproval /
    /// needsInput / needsReview) — the single source of truth those callers share.
    public var isGate: Bool { kind == .gate }
}

/// Visual treatment of a board column, mapped from `TaskStage.kind`.
public enum TaskColumnKind: String { case standard, handoff, gate, agent, warn, done }

/// The owner-segmented board lens. Each view shows a different column set; Inbox and
/// Done are shared across all three.
public enum BoardOwnerView: String, CaseIterable, Identifiable {
    case everyone, mine, agent
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .everyone: "Everyone"
        case .mine: "Mine"
        case .agent: "✦ Agent"
        }
    }

    public var caption: String {
        switch self {
        case .everyone: "Everyone — the full pipeline, yours and the agent’s together."
        case .mine: "Mine — just your own work."
        case .agent: "Agent — hand-offs run through For Agent → Needs Approval → Needs Review."
        }
    }

    public var columns: [TaskStage] {
        switch self {
        case .everyone:
            [.inbox, .planned, .scheduled, .forAgent, .needsApproval,
             .queued, .inProgress, .needsInput, .needsReview, .blocked, .done]
        case .mine:
            [.inbox, .planned, .scheduled, .inProgress, .blocked, .done]
        case .agent:
            [.inbox, .forAgent, .needsApproval, .queued, .inProgress,
             .needsInput, .needsReview, .done]
        }
    }
}

/// A link shown on a Needs Review card (Shortcut / Jira / draft).
public struct TaskLink: Codable, Hashable {
    public var label: String
    public var url: String
    public init(label: String, url: String) { self.label = label; self.url = url }
}
