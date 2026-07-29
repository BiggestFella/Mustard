import Foundation

/// Splits a finalized transcript into context-budget-sized chunks for digest
/// generation (meeting recorder Task 7, BAK-299). Pure and deterministic:
/// greedy fill against an injected token counter, cuts preferring silence
/// boundaries (a ≥2s gap between segments) over mid-speech, and an oversized
/// single segment becomes its own chunk — never dropped, never a loop.
public enum MeetingDigestChunker {
    /// A gap this long between segments is a natural cut point.
    public static let silenceBoundary: TimeInterval = 2.0

    public static func chunks(
        segments: [VoiceTranscriptSegment],
        budgetTokens: Int,
        tokenCount: (String) -> Int
    ) -> [[VoiceTranscriptSegment]] {
        guard !segments.isEmpty else { return [] }
        var result: [[VoiceTranscriptSegment]] = []
        var current: [VoiceTranscriptSegment] = []
        var currentTokens = 0
        /// Index in `current` of the last segment BEFORE a silence gap — the
        /// preferred cut point when the budget overflows.
        var lastSilenceIndex: Int?

        for segment in segments {
            let cost = tokenCount(segment.text)
            if let previous = current.last,
               segment.startSeconds - previous.endSeconds >= silenceBoundary {
                lastSilenceIndex = current.count - 1
            }
            if !current.isEmpty, currentTokens + cost > budgetTokens {
                if let cut = lastSilenceIndex, cut < current.count - 1 {
                    // Cut on silence: close the head, carry the tail forward.
                    result.append(Array(current[...cut]))
                    current = Array(current[(cut + 1)...])
                    currentTokens = current.reduce(0) { $0 + tokenCount($1.text) }
                    lastSilenceIndex = nil
                    if !current.isEmpty, currentTokens + cost > budgetTokens {
                        result.append(current)
                        current = []
                        currentTokens = 0
                    }
                } else {
                    result.append(current)
                    current = []
                    currentTokens = 0
                    lastSilenceIndex = nil
                }
            }
            // An oversized single segment lands alone in its own chunk — the
            // service hands it to the model as-is rather than dropping words.
            current.append(segment)
            currentTokens += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Digest value types (pure; the generation service is macOS-only)

/// Why digest generation failed — always locally retryable; the meeting
/// stays recorded and transcribed regardless (spec: a digest failure never
/// degrades the recording).
public enum MeetingDigestFailure: Error, Equatable, Sendable {
    case model(LocalModelFailure)
    case missingPrompt
}

/// The validated digest: every action's evidence verified against the real
/// transcript, dates resolved deterministically, stamped for traceability.
public struct MeetingDigest: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public var title: String
        public var owner: String?
        public var due: Date?
        public var evidenceSegmentIDs: [String]
    }

    public var summary: String
    public var decisions: [String]
    public var unresolvedQuestions: [String]
    public var actions: [Action]
    public var promptVersion: String
    public var osBuild: String
}

