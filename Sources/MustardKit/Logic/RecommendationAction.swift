import Foundation

/// What the agent proposes to do with a recommendation. Raw values are the
/// tokens stored on `Recommendation.proposedActionType` and emitted by the sweep.
public enum RecommendationAction: String, CaseIterable, Identifiable {
    case draftEmail = "draft_email"
    case draftSlack = "draft_slack"
    case createTask = "create_task"
    case vaultNote = "vault_note"
    case ticket = "ticket_write"
    case fyi = "fyi"
    case ignore = "ignore"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .draftEmail: "Draft email"
        case .draftSlack: "Draft Slack"
        case .createTask: "Create task"
        case .vaultNote: "Update vault"
        case .ticket: "Create Shortcut"
        case .fyi: "FYI"
        case .ignore: "Ignore"
        }
    }

    /// Outward-facing actions that always require explicit sign-off.
    public var isGated: Bool {
        switch self {
        case .draftEmail, .draftSlack, .ticket: true
        default: false
        }
    }

    /// Known sweep token, or `nil` when the model invented something we don't
    /// understand. Callers that execute or auto-approve must use this — never
    /// `from`, which is a display fallback.
    public static func parse(_ raw: String) -> RecommendationAction? {
        RecommendationAction(rawValue: raw)
    }

    /// Display fallback. Unknown tokens render as "Update vault" so a stale
    /// card still has a label; they must **not** execute as a vault note.
    /// Trust and `decide` fail closed via `parse` / `TrustPolicy.isGated`.
    public static func from(_ raw: String) -> RecommendationAction {
        parse(raw) ?? .vaultNote
    }
}
