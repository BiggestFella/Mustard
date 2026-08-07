import Foundation

/// Deterministic two-source transcript merging (meeting recorder Task 5,
/// BAK-297). Pure: finals only, same-id provisional replacement (the final
/// wins), ordered by start, then end, then source (You before Meeting), then
/// stable id — so re-merging the same inputs always yields the same timeline.
public enum MeetingTranscriptMerge {
    public static func merged(
        you: [VoiceTranscriptSegment],
        meeting: [VoiceTranscriptSegment]
    ) -> [VoiceTranscriptSegment] {
        (finalsOnly(you) + finalsOnly(meeting)).sorted { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            if lhs.endSeconds != rhs.endSeconds { return lhs.endSeconds < rhs.endSeconds }
            if lhs.source != rhs.source { return sourceOrder(lhs.source) < sourceOrder(rhs.source) }
            return lhs.id < rhs.id
        }
    }

    /// The persistence id for a merged segment: namespaced by source so the
    /// same recognizer id ("seg-0.000") from two sources never collides, and
    /// stable across re-merges.
    public static func persistentID(for segment: VoiceTranscriptSegment) -> String {
        "\(segment.source.rawValue):\(segment.id)"
    }

    // MARK: - Helpers

    /// Within one source: the last occurrence of an id wins (a final replaces
    /// its provisional), and only finals survive — provisional-only text is
    /// never persisted.
    private static func finalsOnly(_ segments: [VoiceTranscriptSegment]) -> [VoiceTranscriptSegment] {
        var latest: [String: VoiceTranscriptSegment] = [:]
        for segment in segments { latest[segment.id] = segment }
        return latest.values.filter(\.isFinal)
    }

    /// You (microphone) sorts before Meeting on exact ties.
    private static func sourceOrder(_ source: VoiceAudioSource) -> Int {
        switch source {
        case .microphone: 0
        case .meeting: 1
        }
    }
}
