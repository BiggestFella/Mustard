import Foundation
import SwiftData

/// Where a recorded meeting sits on its way from consented start to a
/// reviewed digest. Persisted string-backed (CloudKit-shaped); the richer
/// transient machine lives in `Logic/MeetingRecordingState`.
public enum MeetingStatus: String, Codable, CaseIterable, Sendable {
    case preparing, recording, finalizing, ready, partial, failed
}

/// The on-device digest's own lifecycle — independent of the audio, so a
/// digest failure never degrades the recording (spec: locally retryable).
public enum MeetingDigestStatus: String, Codable, CaseIterable, Sendable {
    case pending, generating, ready, failed
}

/// One recorded meeting (meeting recorder Task 1, BAK-293). Audio never lives
/// in SwiftData — the record stores validated RELATIVE paths under Mustard's
/// Application Support container (`MeetingAudioStore` owns the directory
/// layout). Every field is optional or defaulted (CloudKit-shaped, ADR-0004).
@Model
public final class MeetingRecord {
    public var uid: String = UUID().uuidString
    public var title: String = ""
    /// Conference provider hint ("zoom", "meet", …) when detected.
    public var provider: String?
    public var statusRaw: String = MeetingStatus.preparing.rawValue
    public var digestStatusRaw: String = MeetingDigestStatus.pending.rawValue
    public var startedAt: Date?
    public var endedAt: Date?
    public var conferenceURL: String?
    /// Which sources were captured ("you", "meeting") — metadata, not truth;
    /// the audio files themselves are the truth.
    public var captureSources: [String] = []
    /// Validated relative audio paths (never absolute; see
    /// `validatedRelativeAudioPath`).
    public var youAudioPath: String?
    public var meetingAudioPath: String?
    public var playbackAudioPath: String?
    public var audioFinalized: Bool = false
    /// Traceability for generated digests (Apple exposes no model version).
    public var promptVersion: String?
    public var osBuild: String?
    public var retentionDeadline: Date?
    public var pinned: Bool = false
    public var errorMessage: String?
    /// Serialized recovery breadcrumb when a crash left partials.
    public var recoveryStateRaw: String?
    public var createdAt: Date = Date.now

    public var calendarEvent: CalendarEvent?
    @Relationship(deleteRule: .cascade, inverse: \MeetingTranscriptSegment.meeting)
    public var segments: [MeetingTranscriptSegment]? = []
    @Relationship(deleteRule: .cascade, inverse: \MeetingActionProposal.meeting)
    public var proposals: [MeetingActionProposal]? = []

    public init(title: String = "") {
        self.title = title
    }

    public var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .preparing }
        set { statusRaw = newValue.rawValue }
    }

    public var digestStatus: MeetingDigestStatus {
        get { MeetingDigestStatus(rawValue: digestStatusRaw) ?? .pending }
        set { digestStatusRaw = newValue.rawValue }
    }

    /// Audio paths persist as validated RELATIVE paths only (spec §Files):
    /// nothing absolute, nothing home-relative, no traversal. Returns nil for
    /// anything unsafe — the caller must not store it.
    public static func validatedRelativeAudioPath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let components = path.split(separator: "/")
        guard !components.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        return path
    }
}
