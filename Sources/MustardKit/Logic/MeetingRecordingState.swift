import Foundation

/// Pure meeting-recorder lifecycle (meeting recorder, Task 2). The impure
/// coordinator (ScreenCaptureKit, writers, transcription — later tasks) only
/// ever changes state through `applying(_:)`, so every legal edge is decided
/// and unit-tested here.
///
/// Codable so the crash-recovery manifest (`MeetingRecoveryManifest`) can
/// persist the last durable state verbatim.
public enum MeetingRecordingState: Equatable, Codable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case paused
    case finalizingAudio
    case finalizingTranscript
    case summarizing
    case ready
    /// An interruption (crash, forced termination, device loss) left durable
    /// partial audio behind. The payload is the human-readable reason; the
    /// manifest carries the recoverable byte/sample positions.
    case partial(String)
    case failed(String)
}

/// Everything that can happen to a recording. Suggested/detected meetings are
/// never consent: only `.userConfirmedStart` — an explicit user action — may
/// move `preparing` to `recording`.
public enum MeetingRecordingEvent: Equatable {
    case prepare
    /// Explicit user confirmation (the Start button after the consent prompt).
    case userConfirmedStart(at: Date)
    case pause
    /// The coordinator passes back the original session start (persisted in
    /// the manifest) so elapsed time stays truthful across a pause.
    case resume(at: Date)
    case stop
    case audioFinalized
    case transcriptFinalized
    case digestReady
    /// Terminal failure — nothing recoverable remains to try.
    case fail(reason: String)
    /// Recoverable interruption — durable partial audio survives.
    case interrupted(reason: String)
    /// Resume a `partial` meeting from its manifest: finalize the safely
    /// written chunks and continue down the ordinary pipeline.
    case recover
}

extension MeetingRecordingState {
    /// The single transition function. Returns the next state, or `nil` when
    /// the event is illegal here — the caller keeps the current state, which
    /// is what preserves `partial` against stray events after an interruption.
    public func applying(_ event: MeetingRecordingEvent) -> MeetingRecordingState? {
        switch (self, event) {
        case (.idle, .prepare):
            return .preparing

        // The consent gate: explicit confirmation is the only way in, and only
        // from preparing — a second start while recording/paused is rejected.
        case (.preparing, .userConfirmedStart(let date)):
            return .recording(startedAt: date)

        case (.recording, .pause):
            return .paused
        case (.paused, .resume(let date)):
            return .recording(startedAt: date)

        case (.recording, .stop), (.paused, .stop):
            return .finalizingAudio

        case (.finalizingAudio, .audioFinalized):
            return .finalizingTranscript
        case (.finalizingTranscript, .transcriptFinalized):
            return .summarizing
        case (.summarizing, .digestReady):
            return .ready

        // Interruption preserves partial work; recovery re-enters the pipeline
        // at audio finalization (the manifest says what was safely written).
        case (.recording, .interrupted(let reason)),
             (.paused, .interrupted(let reason)),
             (.finalizingAudio, .interrupted(let reason)),
             (.finalizingTranscript, .interrupted(let reason)),
             (.summarizing, .interrupted(let reason)):
            return .partial(reason)
        case (.partial, .recover):
            return .finalizingAudio

        // Terminal failure from any active (or partial) state; idle, ready and
        // failed never fail.
        case (.preparing, .fail(let reason)),
             (.recording, .fail(let reason)),
             (.paused, .fail(let reason)),
             (.finalizingAudio, .fail(let reason)),
             (.finalizingTranscript, .fail(let reason)),
             (.summarizing, .fail(let reason)),
             (.partial, .fail(let reason)):
            return .failed(reason)

        default:
            return nil
        }
    }
}
