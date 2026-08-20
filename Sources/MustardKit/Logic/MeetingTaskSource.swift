import Foundation

/// Provenance tokens for meeting-originated tasks. Two pipelines share a
/// `meeting*` prefix but **not** the same approval gate:
///
/// - `"meeting"` — vault-harvested ledger lines (F17). These flood the board if
///   they auto-run, so they must carry `agentApprovalGranted` (Do/Don't).
/// - `"meeting-recording"` — recorder proposals already approved locally
///   (`MeetingActionApproval`). A second Claude-queue gate would strand them.
public enum MeetingTaskSource {
    public static let ledger = "meeting"
    public static let recording = "meeting-recording"

    /// True only for vault-harvested ledger work. The agent queue, board move
    /// grant/clear, and interrupted-run reconcile must all use this — never a
    /// `hasPrefix("meeting")` that also matches recordings.
    public static func requiresAgentApproval(_ source: String) -> Bool {
        source == ledger
    }
}
