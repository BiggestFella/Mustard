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
    /// Ceiling on ONE session's finalization. A SpeechAnalyzer session that
    /// received no audio never returns from finish(), which stranded stop()
    /// forever on hardware — the recording is already safe on disk by then, so
    /// a timeout costs at most one channel's transcript.
    private let finalizeTimeout: TimeInterval

    private var youSession: (any VoiceTranscribing)?
    private var meetingSession: (any VoiceTranscribing)?

    public init(
        makeSession: @escaping @MainActor () async throws -> any VoiceTranscribing,
        isInsufficientResources: @escaping (Error) -> Bool,
        transcribeFile: @escaping @MainActor (URL) async throws -> [VoiceTranscriptSegment],
        finalizeTimeout: TimeInterval = 20
    ) {
        self.makeSession = makeSession
        self.isInsufficientResources = isInsufficientResources
        self.transcribeFile = transcribeFile
        self.finalizeTimeout = finalizeTimeout
    }

    /// Start the You session, then try the Meeting session; an
    /// insufficient-resources failure selects the sequential fallback, any
    /// other failure propagates (never a silent degradation).
    public func start(sources: [MeetingAudioSource]) async throws {
        let you = try await makeSession()
        _ = try await you.start(source: .microphone)
        youSession = you

        // No system audio being captured means nothing will ever feed a live
        // Meeting session, and finalizing a starved one hangs. Don't make one.
        guard sources.contains(.systemAudio) else {
            meetingSession = nil
            mode = .liveYouThenMeetingFile
            return
        }

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
        let youFinals = await boundedFinish(youSession)
        youSession = nil

        let meetingFinals: [VoiceTranscriptSegment]
        switch mode {
        case .dualLive:
            meetingFinals = await boundedFinish(meetingSession)
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

    /// Race one session's finalization against the ceiling. On timeout the
    /// session is cancelled to release its resources and the channel
    /// contributes nothing, rather than stranding Stop forever.
    private func boundedFinish(_ session: (any VoiceTranscribing)?) async -> [VoiceTranscriptSegment] {
        guard let session else { return [] }
        var resumed = false
        let raced: [VoiceTranscriptSegment]? = await withCheckedContinuation { continuation in
            let resumeOnce: @MainActor ([VoiceTranscriptSegment]?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                let finals = try? await session.finish()
                resumeOnce(finals ?? [])
            }
            Task { @MainActor [finalizeTimeout] in
                try? await Task.sleep(for: .seconds(finalizeTimeout))
                resumeOnce(nil)
            }
        }
        guard let raced else {
            await session.cancel()
            return []
        }
        return raced
    }
}

// MARK: - Live wiring (macOS; exercised in the meeting matrix)

#if os(macOS)
extension MeetingTranscriptionService {
    /// Production transcription: fresh SpeechAnalyzer sessions per source
    /// (macOS 27's live driver — earlier installs get a clear failure), a
    /// resource-exhaustion fallback on the second session, and the
    /// after-Stop file transcriber.
    @MainActor
    public static func liveMeeting() -> MeetingTranscriptionService {
        MeetingTranscriptionService(
            makeSession: {
                guard #available(macOS 27.0, *) else {
                    throw VoiceSessionError.notReady(
                        .unavailable("Meeting transcription needs macOS 27"))
                }
                return AppleSpeechSession.live()
            },
            isInsufficientResources: { error in
                // Readiness/permission problems must propagate (no silent
                // degradation); runtime allocation failures on the second
                // session select the sequential fallback instead.
                if case VoiceSessionError.notReady = error { return false }
                return true
            },
            transcribeFile: { url in
                guard #available(macOS 27.0, *) else { return [] }
                return try await transcribeAudioFile(url)
            })
    }

    /// Post-process one finalized audio file through a fresh session —
    /// the sequential fallback's second half.
    @available(macOS 27.0, *)
    @MainActor
    static func transcribeAudioFile(_ url: URL) async throws -> [VoiceTranscriptSegment] {
        let session = AppleSpeechSession.live()
        _ = try await session.start(source: .meeting)
        let file = try AVAudioFile(forReading: url)
        let chunkFrames: AVAudioFrameCount = 48_000
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try await session.append(buffer, at: nil)
        }
        return try await session.finish()
    }
}
#endif
