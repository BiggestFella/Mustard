import Foundation
import SwiftData

/// Which channel a transcript segment came from: Leon's microphone ("you")
/// or the other side playing through the Mac ("meeting").
public enum MeetingSegmentSource: String, Codable, CaseIterable, Sendable {
    case you, meeting
}

/// One stable span of meeting transcript (meeting recorder Task 1, BAK-293).
/// `rawText` is immutable evidence — user corrections live separately on
/// `correctedText`, so generated digests can always cite what was actually
/// heard (spec §Privacy and evidence).
@Model
public final class MeetingTranscriptSegment {
    public var uid: String = UUID().uuidString
    public var meeting: MeetingRecord?
    public var sourceRaw: String = MeetingSegmentSource.you.rawValue
    public var startSeconds: Double = 0
    public var endSeconds: Double = 0
    /// The recognizer's stable text, exactly as finalized. Never edited.
    public var rawText: String = ""
    /// Leon's correction, when he makes one; nil otherwise.
    public var correctedText: String?
    public var confidence: Double?

    public init(
        rawText: String = "",
        source: MeetingSegmentSource = .you,
        startSeconds: Double = 0,
        endSeconds: Double = 0,
        confidence: Double? = nil
    ) {
        self.rawText = rawText
        self.sourceRaw = source.rawValue
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }

    public var source: MeetingSegmentSource {
        get { MeetingSegmentSource(rawValue: sourceRaw) ?? .you }
        set { sourceRaw = newValue.rawValue }
    }
}
