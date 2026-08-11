import Foundation

/// Splits a finalized transcript into context-budget-sized chunks for digest
/// generation (meeting recorder Task 7, BAK-299). Pure and deterministic:
/// greedy fill against an injected token counter, cuts preferring silence
/// boundaries (a ≥2s gap between segments) over mid-speech, and an oversized
/// single segment becomes its own chunk — never dropped, never a loop.
public enum MeetingDigestChunker {
    /// A gap this long between segments is a natural cut point.
    public static let silenceBoundary: TimeInterval = 2.0

    /// The exact prompt line `MeetingDigestService.chunkPrompt` renders for
    /// one segment: `[<persistentID>] (<channel> <start>–<end>s): <text>`.
    /// This is the single source of truth for that line — the service calls
    /// it to build the prompt, and `chunks` costs against it, so the budget
    /// this file enforces can never drift from what the model actually sees.
    public static func renderedLine(for segment: VoiceTranscriptSegment) -> String {
        let channel = segment.source == .meeting ? "meeting" : "you"
        return "[\(MeetingTranscriptMerge.persistentID(for: segment))] (\(channel) "
            + String(format: "%.1f–%.1fs", segment.startSeconds, segment.endSeconds)
            + "): \(segment.text)"
    }

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
            let cost = tokenCount(Self.renderedLine(for: segment))
            if let previous = current.last,
               segment.startSeconds - previous.endSeconds >= silenceBoundary {
                lastSilenceIndex = current.count - 1
            }
            if !current.isEmpty, currentTokens + cost > budgetTokens {
                if let cut = lastSilenceIndex, cut < current.count - 1 {
                    // Cut on silence: close the head, carry the tail forward.
                    result.append(Array(current[...cut]))
                    current = Array(current[(cut + 1)...])
                    currentTokens = current.reduce(0) { $0 + tokenCount(Self.renderedLine(for: $1)) }
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

/// A persistable, user-facing surface over `MeetingDigestFailure` (BAK-331).
/// Plain rawValue enum — deliberately drops `LocalModelFailure.unavailable`'s
/// associated detail string rather than persisting it, since that text could
/// carry arbitrary model output.
public enum MeetingDigestFailureReason: String, Codable, CaseIterable, Sendable {
    case contextOverflow
    case appleIntelligenceDisabled
    case deviceNotEligible
    case modelNotReady
    case unsupportedLocale
    case missingPrompt
    case unavailable

    public init(failure: MeetingDigestFailure) {
        switch failure {
        case .missingPrompt:
            self = .missingPrompt
        case .model(let modelFailure):
            switch modelFailure {
            case .contextOverflow: self = .contextOverflow
            case .appleIntelligenceDisabled: self = .appleIntelligenceDisabled
            case .deviceNotEligible: self = .deviceNotEligible
            case .modelNotReady: self = .modelNotReady
            case .unsupportedLocale: self = .unsupportedLocale
            case .unavailable: self = .unavailable
            }
        }
    }

    /// Plain-language copy for `MeetingReviewView`'s digest failure caption.
    public var userMessage: String {
        switch self {
        case .contextOverflow:
            return "This meeting is too long for the on-device model to summarise in one pass."
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is turned off — enable it in System Settings, then retry."
        case .deviceNotEligible:
            return "This Mac's hardware can't run the on-device model."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        case .unsupportedLocale:
            return "The on-device model doesn't support this language."
        case .missingPrompt:
            return "Mustard's digest prompt is missing from this build."
        case .unavailable:
            return "The on-device model was unavailable. Try again."
        }
    }

    /// Whether the view should offer a Retry button. `appleIntelligenceDisabled`
    /// is a deliberate deviation from a strict "known cause → no retry"
    /// table: once Leon flips the System Settings switch, retrying is
    /// exactly the fix, so it offers retry unlike the other permanent-cause
    /// failures.
    public var offersRetry: Bool {
        switch self {
        case .contextOverflow, .deviceNotEligible, .unsupportedLocale, .missingPrompt:
            return false
        case .appleIntelligenceDisabled, .modelNotReady, .unavailable:
            return true
        }
    }
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
    /// Transcript ranges (start–end seconds, offset into the meeting) whose
    /// chunk generation failed — BAK-330: a bad chunk degrades the digest to
    /// partial instead of discarding every chunk that DID succeed.
    public var omittedSpans: [ClosedRange<Double>] = []

    public init(
        summary: String,
        decisions: [String],
        unresolvedQuestions: [String],
        actions: [Action],
        promptVersion: String,
        osBuild: String,
        omittedSpans: [ClosedRange<Double>] = []
    ) {
        self.summary = summary
        self.decisions = decisions
        self.unresolvedQuestions = unresolvedQuestions
        self.actions = actions
        self.promptVersion = promptVersion
        self.osBuild = osBuild
        self.omittedSpans = omittedSpans
    }

    /// A human-readable note for a partial digest: mm:ss offsets into the
    /// meeting (deliberately timezone-free — these are elapsed-seconds
    /// transcript timestamps, not wall-clock times), multiple spans joined
    /// with "; ". `nil` when nothing was omitted.
    public static func omissionNote(spans: [ClosedRange<Double>]) -> String? {
        guard !spans.isEmpty else { return nil }
        let ranges = spans.map { "\(offset($0.lowerBound))–\(offset($0.upperBound))" }
        return "\(ranges.joined(separator: "; ")) into the meeting could not be summarised."
    }

    /// Renders elapsed seconds as `m:ss`, minutes rolling past 60 rather than
    /// wrapping into an hour component.
    private static func offset(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

