import Foundation

public enum TrustLevel: String, Codable, CaseIterable, Identifiable {
    case manual, supervised, trusted, autonomous
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual: "Manual"
        case .supervised: "Supervised"
        case .trusted: "Trusted"
        case .autonomous: "Autonomous"
        }
    }

    /// The next level in the tap-cycle, wrapping autonomous → manual (mobile Triage
    /// deck's trust chip, BAK-119).
    public var next: TrustLevel {
        let all = TrustLevel.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// Higher = more autonomy. Used for threshold comparisons.
    public var rank: Int {
        switch self {
        case .manual: 0
        case .supervised: 1
        case .trusted: 2
        case .autonomous: 3
        }
    }

    /// Plain-English explanation shown under the Trust control. Trusted/Autonomous
    /// copy matches ADR-0010: completed work always lands in Needs Review.
    public var blurb: String {
        switch self {
        case .manual: "You approve everything. The agent only proposes — nothing runs on its own."
        case .supervised: "Non-gated work runs automatically; you review every output before it counts. Email, Slack and tickets stay gated."
        case .trusted: "The agent runs non-gated work on its own. Every result still lands in Needs Review. Email, Slack and tickets stay gated."
        case .autonomous: "Maximum autonomy on non-gated work. Always-gated actions (email, Slack, tickets) still wait for you, and completed work still goes to Needs Review."
        }
    }
}

/// Decides how much the agent may do without you. Pure + tested.
public enum TrustPolicy {
    /// Actions that ALWAYS require explicit sign-off, regardless of trust.
    public static let gatedActionTypes: Set<String> = Set(
        RecommendationAction.allCases.filter(\.isGated).map(\.rawValue)
    )

    /// Confidence below this never auto-runs, even when Trusted/Autonomous.
    public static let autoConfidenceThreshold = 0.7

    public static func isGated(actionType: String) -> Bool {
        // Unknown / typo tokens fail closed: a sweep that emits `draft_emial`
        // must not auto-approve as a vault note.
        guard let action = RecommendationAction.parse(actionType) else { return true }
        return action.isGated
    }

    /// May this recommendation execute without a manual Approve?
    /// Requires: not gated, trust ≥ supervised, AND confidence ≥ threshold.
    public static func shouldAutoApprove(
        actionType: String, trust: TrustLevel, confidence: Double = 1.0
    ) -> Bool {
        !isGated(actionType: actionType)
            && trust.rank >= TrustLevel.supervised.rank
            && confidence >= autoConfidenceThreshold
    }

    /// May this execution's output be accepted without a manual Accept?
    public static func shouldAutoAccept(
        actionType: String, trust: TrustLevel, confidence: Double = 1.0
    ) -> Bool {
        !isGated(actionType: actionType)
            && trust.rank >= TrustLevel.trusted.rank
            && confidence >= autoConfidenceThreshold
    }

    /// May a *delegated* task run immediately (vs. queue for your approval)?
    /// Stricter than `shouldAutoApprove`: delegation only auto-runs at Trusted+ —
    /// Manual and Supervised both queue the proposal. Gated + confidence floor still apply.
    public static func shouldAutoRunDelegation(
        actionType: String, trust: TrustLevel, confidence: Double = 1.0
    ) -> Bool {
        !isGated(actionType: actionType)
            && trust.rank >= TrustLevel.trusted.rank
            && confidence >= autoConfidenceThreshold
    }
}
