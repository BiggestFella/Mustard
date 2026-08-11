import Foundation

/// One merged run of adjacent same-source transcript segments — the digest's
/// input unit (BAK-329). Pure value; the persisted transcript is untouched.
public struct MeetingUtterance: Equatable, Sendable {
    /// ≥1 segments, same source, in the time order they were supplied.
    public var segments: [VoiceTranscriptSegment]

    public init(segments: [VoiceTranscriptSegment]) {
        self.segments = segments
    }

    public var source: VoiceAudioSource { segments[0].source }
    public var startSeconds: Double { segments[0].startSeconds }
    public var endSeconds: Double { segments[segments.count - 1].endSeconds }

    /// Constituent texts, trimmed and joined with a single space; empty
    /// (post-trim) texts are skipped so they don't leave a stray space.
    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The persistent id of every constituent, in order — what the digest
    /// prompt and evidence validation key on.
    public var segmentIDs: [String] {
        segments.map(MeetingTranscriptMerge.persistentID(for:))
    }

    /// The utterance rendered as a single segment for the digest pipeline:
    /// id is the FIRST constituent's RAW id (the caller namespaces it via
    /// `MeetingTranscriptMerge.persistentID`, and that id is real, persisted
    /// evidence), span covers the whole run, text is the merged text,
    /// confidence is the mean of constituents that reported one.
    public var asSegment: VoiceTranscriptSegment {
        let confidences = segments.compactMap(\.confidence)
        let meanConfidence: Double? = confidences.isEmpty
            ? nil
            : confidences.reduce(0, +) / Double(confidences.count)
        return VoiceTranscriptSegment(
            id: segments[0].id,
            text: text,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            isFinal: true,
            confidence: meanConfidence,
            source: source)
    }
}

/// Merges near-word-level transcriber finals into speech-shaped utterances
/// before digest generation (BAK-329). A real 23-minute standup persisted
/// 1,145 segments (~15 chars each) for 3,176 words; each segment costs a
/// ~44-char id/timing prefix in the digest prompt
/// (`MeetingDigestChunker.renderedLine`), so most of the prompt was
/// bookkeeping. Merging adjacent same-source segments on a short-pause rule
/// collapses that down to a few hundred utterances without touching the
/// persisted transcript — the merge is a pure view over it.
public enum MeetingUtteranceMerge {
    /// A gap this long (or longer) between adjacent same-source segments
    /// ends the current utterance.
    public static let pauseThreshold: TimeInterval = 1.5

    /// Hard cap (characters) on one utterance's merged text — breaks
    /// pathological monologues so no single utterance can approach the
    /// model's context window on its own.
    public static let maxTextLength = 2_000

    /// Merges `segments` (assumed time-sorted, as callers already keep them)
    /// into utterances. A run extends only while the next segment shares the
    /// current run's source, starts less than `pauseThreshold` after the
    /// run's last segment ends, and the merged text would still fit
    /// `maxTextLength`. Any other-source segment breaks the run without
    /// reordering anything — interleaving between sources is preserved.
    public static func utterances(
        from segments: [VoiceTranscriptSegment],
        pauseThreshold: TimeInterval = pauseThreshold,
        maxTextLength: Int = maxTextLength
    ) -> [MeetingUtterance] {
        guard !segments.isEmpty else { return [] }

        var result: [MeetingUtterance] = []
        var current: [VoiceTranscriptSegment] = [segments[0]]

        for segment in segments.dropFirst() {
            let previous = current[current.count - 1]
            let sameSource = segment.source == previous.source
            let withinPause = segment.startSeconds - previous.endSeconds < pauseThreshold

            if sameSource, withinPause {
                let candidate = current + [segment]
                if MeetingUtterance(segments: candidate).text.count <= maxTextLength {
                    current = candidate
                    continue
                }
            }
            result.append(MeetingUtterance(segments: current))
            current = [segment]
        }
        result.append(MeetingUtterance(segments: current))
        return result
    }
}
