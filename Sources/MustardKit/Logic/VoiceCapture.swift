import Foundation

/// Pure press-to-talk capture decisions (F25 v1, ADR-0011): whether a hotkey
/// release commits a task, and how a spoken transcript becomes a task title.
/// The impure edges (Carbon hotkey, the SpeechAnalyzer session) live in
/// `Capture/`/`Voice/` and only call through here, so every decision stays
/// unit-tested.
public enum VoiceCapture {
    /// Holds shorter than this cancel — swallows accidental hotkey taps.
    public static let minimumHold: TimeInterval = 0.3

    public enum CancelReason: Equatable {
        case tooShort
        case emptyTranscript
    }

    public enum Outcome: Equatable {
        case commit(title: String)
        case cancelled(CancelReason)
    }

    /// Decide what a hotkey release does. Too-short holds cancel first (a tap is a
    /// tap regardless of what the recognizer produced); then an empty transcript
    /// cancels; otherwise commit with the normalized title.
    public static func outcome(pressedAt: Date, releasedAt: Date, transcript: String) -> Outcome {
        // 1ms tolerance: Date stores seconds as a Double, so an interval built to be
        // exactly `minimumHold` can compare a hair under it. Imperceptible for UX.
        guard releasedAt.timeIntervalSince(pressedAt) >= minimumHold - 0.001 else {
            return .cancelled(.tooShort)
        }
        let title = normalizeTitle(transcript)
        guard !title.isEmpty else { return .cancelled(.emptyTranscript) }
        return .commit(title: title)
    }

    // MARK: - Segment → text (modern engine, Capture Task 3)

    /// The verbatim raw transcript a commit stores: FINAL segments only,
    /// ordered by start time (id breaks ties), texts joined with one space.
    public static func transcript(from segments: [VoiceTranscriptSegment]) -> String {
        liveTranscript(segments.filter(\.isFinal))
    }

    /// The live pill text while recording: every segment's latest revision
    /// (the caller replaces same-id provisionals), same ordering and joining.
    public static func liveTranscript(_ segments: [VoiceTranscriptSegment]) -> String {
        segments
            .sorted { ($0.startSeconds, $0.id) < ($1.startSeconds, $1.id) }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// How many spoken words a placeholder title keeps before trailing off.
    public static let fallbackTitleWordLimit = 8

    /// The title a fresh capture is born with. The spoken words themselves go
    /// into the task's notes — a long dictation makes an unreadable title —
    /// so this is only a readable stub until on-device drafting proposes a
    /// real one. It must never be empty: a task with no name is worse than a
    /// clumsy one, and drafting is allowed to fail.
    public static func fallbackTitle(from transcript: String) -> String {
        let normalized = normalizeTitle(transcript)
        guard !normalized.isEmpty else { return "Voice note" }
        let words = normalized.split(separator: " ")
        guard words.count > fallbackTitleWordLimit else { return normalized }
        return words.prefix(fallbackTitleWordLimit).joined(separator: " ") + "…"
    }

    /// Transcript → title: trim, collapse whitespace runs (incl. newlines) to single
    /// spaces, drop one trailing full stop (recognizers punctuate most utterances
    /// with "." — noise in a title; "?"/"!" are kept), and capitalize the first letter.
    public static func normalizeTitle(_ transcript: String) -> String {
        var text = transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.hasSuffix(".") && !text.hasSuffix("..") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
