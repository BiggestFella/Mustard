import Foundation
import AVFoundation

/// How a meeting is transcribed — decided at start, never silently degraded
/// (meeting recorder Task 5, BAK-297).
public enum MeetingTranscriptionMode: Equatable, Sendable {
    /// Two live sessions, one per source.
    case dualLive
    /// The analyzer stack couldn't run two sessions: You transcribes live,
    /// the Meeting track keeps RECORDING and its audio file is transcribed
    /// after Stop, then the two merge.
    case liveYouThenMeetingFile
}

/// Runs transcription for one meeting over injected sessions: dual-live when
/// resources allow, else the sequential fallback. Recording itself is the
/// writer's job and never stops because transcription degraded.
@MainActor
public final class MeetingTranscriptionService {
    public private(set) var mode: MeetingTranscriptionMode?

    private let makeSession: @MainActor () async throws -> any VoiceTranscribing
    private let isInsufficientResources: (Error) -> Bool
    private let transcribeFile: @MainActor (URL) async throws -> [VoiceTranscriptSegment]

    private var youSession: (any VoiceTranscribing)?
    private var meetingSession: (any VoiceTranscribing)?

    public init(
        makeSession: @escaping @MainActor () async throws -> any VoiceTranscribing,
        isInsufficientResources: @escaping (Error) -> Bool,
        transcribeFile: @escaping @MainActor (URL) async throws -> [VoiceTranscriptSegment]
    ) {
        self.makeSession = makeSession
        self.isInsufficientResources = isInsufficientResources
        self.transcribeFile = transcribeFile
    }

    /// Start the You session, then try the Meeting session; an
    /// insufficient-resources failure selects the sequential fallback, any
    /// other failure propagates (never a silent degradation).
    public func start() async throws {
        let you = try await makeSession()
        _ = try await you.start(source: .microphone)
        youSession = you

        let meeting = try await makeSession()
        do {
            _ = try await meeting.start(source: .meeting)
            meetingSession = meeting
            mode = .dualLive
        } catch where isInsufficientResources(error) {
            meetingSession = nil
            mode = .liveYouThenMeetingFile
        }
    }

    /// Route one PCM chunk to its live session. In the fallback mode the
    /// Meeting channel has no live session — its audio is already being
    /// persisted by the writer and is transcribed after Stop.
    public func append(_ buffer: AVAudioPCMBuffer, channel: MeetingSegmentSource) async throws {
        switch channel {
        case .you:
            try await youSession?.append(buffer, at: nil)
        case .meeting:
            try await meetingSession?.append(buffer, at: nil)
        }
    }

    /// Finalize the live session(s), post-process the meeting file when in
    /// fallback mode, and return the merged, ordered, finals-only timeline.
    public func stop(meetingAudioFile: URL?) async throws -> [VoiceTranscriptSegment] {
        let youFinals = try await youSession?.finish() ?? []
        youSession = nil

        let meetingFinals: [VoiceTranscriptSegment]
        switch mode {
        case .dualLive:
            meetingFinals = try await meetingSession?.finish() ?? []
        case .liveYouThenMeetingFile:
            if let meetingAudioFile {
                meetingFinals = try await transcribeFile(meetingAudioFile)
            } else {
                meetingFinals = []
            }
        case nil:
            meetingFinals = []
        }
        meetingSession = nil
        mode = nil

        return MeetingTranscriptMerge.merged(you: youFinals, meeting: meetingFinals)
    }
}
