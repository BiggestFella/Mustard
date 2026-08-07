import Foundation
import SwiftData

/// A proposed action item's review state. Proposals are ALWAYS
/// approval-gated — nothing becomes a task without Leon's yes.
public enum MeetingProposalState: String, Codable, CaseIterable, Sendable {
    case pending, approved, rejected
}

/// One digest-proposed action item (meeting recorder Task 1, BAK-293).
/// Carries the transcript-segment UIDs that support it, so every proposal is
/// evidence-backed; approval links AT MOST one created task (to-one, nullify —
/// the task outlives its meeting).
@Model
public final class MeetingActionProposal {
    public var uid: String = UUID().uuidString
    public var meeting: MeetingRecord?
    public var title: String = ""
    public var notes: String?
    /// Suggested owner ("me"/"agent"), advisory only until approval.
    public var owner: String?
    public var scheduledFor: Date?
    public var areaName: String?
    /// UIDs of the `MeetingTranscriptSegment`s that support this proposal.
    public var supportingSegmentUIDs: [String] = []
    public var stateRaw: String = MeetingProposalState.pending.rawValue
    @Relationship(deleteRule: .nullify)
    public var createdTask: MustardTask?

    public init(
        title: String = "",
        notes: String? = nil,
        owner: String? = nil,
        scheduledFor: Date? = nil,
        areaName: String? = nil,
        supportingSegmentUIDs: [String] = []
    ) {
        self.title = title
        self.notes = notes
        self.owner = owner
        self.scheduledFor = scheduledFor
        self.areaName = areaName
        self.supportingSegmentUIDs = supportingSegmentUIDs
    }

    public var state: MeetingProposalState {
        get { MeetingProposalState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}
