import Foundation

/// Where a dictation hold spent its time (Talkify review, item 5).
///
/// Before this existed nobody could say whether dictation felt slow because of
/// 200ms or 900ms, so every proposed speed-up was a guess. Two numbers answer
/// it:
///
/// - **startup** — key-down to the microphone actually being live. Audio spoken
///   inside this window used to be lost outright (see `MicrophonePreRoll`).
/// - **finish** — key-up to the words landing in the field. This is the
///   recognizer's finalization plus insertion.
///
/// Pure and clock-injected: the coordinator passes its own `now`, so the marks
/// are deterministic in tests and never read the ambient clock.
public struct DictationLatency: Equatable, Sendable {
    public private(set) var pressedAt: Date?
    public private(set) var listeningAt: Date?
    public private(set) var releasedAt: Date?
    public private(set) var insertedAt: Date?

    public init() {}

    /// Begins a fresh measurement. Deliberately clears everything else: a
    /// previous hold's release or insertion leaking into the next hold's
    /// numbers would silently corrupt the very thing this unit exists to
    /// measure.
    public mutating func markPressed(_ date: Date) {
        pressedAt = date
        listeningAt = nil
        releasedAt = nil
        insertedAt = nil
    }

    public mutating func markListening(_ date: Date) {
        listeningAt = date
    }

    public mutating func markReleased(_ date: Date) {
        releasedAt = date
    }

    public mutating func markInserted(_ date: Date) {
        insertedAt = date
    }

    /// Key-down → microphone live.
    public var startupMilliseconds: Int? {
        Self.milliseconds(from: pressedAt, to: listeningAt)
    }

    /// Key-down → key-up. Context for the other two, not a latency itself.
    public var heldMilliseconds: Int? {
        Self.milliseconds(from: pressedAt, to: releasedAt)
    }

    /// Key-up → words in the field.
    public var finishMilliseconds: Int? {
        Self.milliseconds(from: releasedAt, to: insertedAt)
    }

    /// One log line, or nil when nothing is measurable yet. Only the
    /// measurements that exist are reported — a hold that ended in recovery
    /// still tells us what its startup cost.
    public var summary: String? {
        var parts: [String] = []
        if let startup = startupMilliseconds { parts.append("startup=\(startup)ms") }
        if let held = heldMilliseconds { parts.append("held=\(held)ms") }
        if let finish = finishMilliseconds { parts.append("finish=\(finish)ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Rounded whole milliseconds, or nil when either end is missing or the
    /// interval runs backwards. A wall-clock adjustment mid-hold must produce
    /// no number rather than a negative one — a bogus measurement in the log
    /// is worse than a missing one.
    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }
        return Int((interval * 1000).rounded())
    }
}
