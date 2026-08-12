import XCTest
import SwiftData
import AVFoundation
@testable import MustardKit

/// The manual meeting recorder's coordinator (Meetings Task 6, BAK-298):
/// explicit consent before any capture, duplicate prevention, pause/resume,
/// the stop pipeline (finalize → transcribe → persist → ready), typed
/// failures that persist their reason, per-source degradation, and launch
/// recovery. Capture and speech are stubs; the writer runs on a temp store.
@MainActor
final class MeetingCaptureCoordinatorTests: XCTestCase {

    private var root: URL!
    private var store: MeetingAudioStore!
    private let t0 = Date(timeIntervalSince1970: 1_784_714_400)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-meeting-coordinator-\(UUID().uuidString)/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingAudioStore(recordingsRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
            MustardTask.self, Area.self, TaskList.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func pcm(frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    private final class StubCapturing: MeetingAudioCapturing, @unchecked Sendable {
        var available: [MeetingAudioSource] = [.microphone, .systemAudio]
        var availableError: Error?
        var continuations: [MeetingAudioSource: AsyncThrowingStream<MeetingAudioSample, Error>.Continuation] = [:]
        private(set) var paused = 0
        private(set) var resumed = 0
        private(set) var stopped = false
        private(set) var started: [MeetingAudioSource] = []

        func availableSources() async throws -> [MeetingAudioSource] {
            if let availableError { throw availableError }
            return available
        }
        func start(source: MeetingAudioSource) async throws -> AsyncThrowingStream<MeetingAudioSample, Error> {
            started.append(source)
            return AsyncThrowingStream { self.continuations[source] = $0 }
        }
        func pause() async throws { paused += 1 }
        func resume() async throws { resumed += 1 }
        func stop() async throws {
            stopped = true
            for continuation in continuations.values { continuation.finish() }
        }
    }

    private final class StubSession: VoiceTranscribing, @unchecked Sendable {
        let finals: [VoiceTranscriptSegment]
        init(finals: [VoiceTranscriptSegment]) { self.finals = finals }
        func readiness() async -> VoiceReadiness { .ready }
        func prepare() async throws {}
        func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws {}
        func finish() async throws -> [VoiceTranscriptSegment] { finals }
        func cancel() async {}
    }

    private func transcription(
        youFinals: [VoiceTranscriptSegment] = [],
        meetingFinals: [VoiceTranscriptSegment] = []
    ) -> MeetingTranscriptionService {
        var handed = [
            StubSession(finals: youFinals),
            StubSession(finals: meetingFinals),
        ]
        return MeetingTranscriptionService(
            makeSession: { handed.isEmpty ? StubSession(finals: []) : handed.removeFirst() },
            isInsufficientResources: { _ in false },
            transcribeFile: { _ in [] })
    }

    private func makeCoordinator(
        context: ModelContext,
        capturing: StubCapturing,
        transcription service: MeetingTranscriptionService? = nil,
        writerThrows: Bool = false,
        digest: ((_ segments: [VoiceTranscriptSegment], _ now: Date) async -> Result<MeetingDigest, MeetingDigestFailure>)? = nil
    ) -> MeetingCaptureCoordinator {
        struct DiskFull: Error {}
        let store = self.store!
        return MeetingCaptureCoordinator(
            context: context,
            capturing: capturing,
            store: store,
            makeWriter: { uid, startedAt in
                if writerThrows { throw DiskFull() }
                return try MeetingAudioWriter(store: store, meetingUID: uid, startedAt: startedAt)
            },
            transcription: service ?? transcription(),
            generateDigest: digest,
            now: { self.t0 })
    }

    private func records(in context: ModelContext) throws -> [MeetingRecord] {
        try context.fetch(FetchDescriptor<MeetingRecord>())
    }

    private func seg(
        _ id: String, _ text: String,
        source: VoiceAudioSource = .microphone,
        start: Double = 0, end: Double = 1
    ) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: end,
            isFinal: true, confidence: nil, source: source)
    }

    // MARK: - Consent & duplicates

    func test_startRequiresExplicitConsent_beforeAnyCaptureRuns() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(context: context, capturing: capturing)

        await coordinator.requestStart(title: "Standup")

        XCTAssertNotNil(coordinator.pendingConfirmation, "recording never starts without a consent prompt")
        XCTAssertTrue(capturing.started.isEmpty, "no audio flows before confirmation")
        XCTAssertEqual(try records(in: context).count, 0, "no record exists before confirmation")

        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        XCTAssertEqual(coordinator.state, .recording(startedAt: t0))
        XCTAssertEqual(capturing.started.sorted { $0.rawValue < $1.rawValue }, [.microphone, .systemAudio])
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .recording)
        XCTAssertEqual(record.title, "Standup")
        XCTAssertEqual(record.startedAt, t0)
    }

    func test_secondStart_isRejectedWhileARecordingIsActive() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(context: context, capturing: capturing)

        await coordinator.requestStart(title: "First")
        await coordinator.confirmStart(sources: [.microphone])
        await coordinator.requestStart(title: "Second")

        XCTAssertNil(coordinator.pendingConfirmation, "an active recording rejects a second start")
        XCTAssertEqual(try records(in: context).count, 1)
    }

    // MARK: - Pause / resume

    func test_pauseAndResume_forwardToCapture_andTransition() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(context: context, capturing: capturing)
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        await coordinator.pause()
        XCTAssertEqual(coordinator.state, .paused)
        XCTAssertEqual(capturing.paused, 1)

        await coordinator.resume()
        XCTAssertEqual(coordinator.state, .recording(startedAt: t0))
        XCTAssertEqual(capturing.resumed, 1)
    }

    // MARK: - Stop pipeline

    func test_stopPipeline_finalizesTranscribesPersists_andReadiesTheRecord() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        // Some audio arrives while recording.
        capturing.continuations[.microphone]?.yield(
            MeetingAudioSample(source: .microphone, buffer: pcm(), hostSeconds: 1))
        for _ in 0..<25 { await Task.yield() }

        await coordinator.stop()

        XCTAssertTrue(capturing.stopped)
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .ready)
        XCTAssertEqual(record.digestStatus, .pending, "the digest is a later task; the meeting is reviewable raw")
        XCTAssertTrue(record.audioFinalized)
        let segments = try context.fetch(FetchDescriptor<MeetingTranscriptSegment>())
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.rawText, "ship it friday")
        XCTAssertEqual(segments.first?.source, .you)
        XCTAssertEqual(record.youAudioPath, "Recordings/\(record.uid)/you.m4a")
        XCTAssertEqual(coordinator.state, .ready)
    }

    // MARK: - Audio/transcript source parity (BAK-332)

    /// Regression for a real incident: a meeting finished `status = ready`,
    /// `audioFinalized = true`, 413 persisted "you" transcript segments — and
    /// zero mic bytes on disk. The writer's `append` silently threw on every
    /// mic buffer (here: a mismatched sample rate, exactly the guard in
    /// `MeetingAudioWriter.append` that a stale post-crash AVFoundation
    /// engine state could trip) while the transcription stub kept receiving
    /// the same buffers and returning real segments regardless — the two
    /// were never compared. This drives that exact shape and asserts the
    /// mismatch is no longer silently clean.
    func test_micWriterNeverWritesAFile_whileTranscriptionSucceeds_flagsParity_keepsRecordingAndTranscript() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        // Mic samples arrive at the WRONG sample rate: MeetingAudioWriter
        // .append throws unsupportedFormat on every one, so the writer never
        // opens a file for this channel — exactly the incident's mechanism.
        // The system-audio channel writes normally.
        let badFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let badBuffer = AVAudioPCMBuffer(pcmFormat: badFormat, frameCapacity: 4_410)!
        badBuffer.frameLength = 4_410
        capturing.continuations[.microphone]?.yield(
            MeetingAudioSample(source: .microphone, buffer: badBuffer, hostSeconds: 1))
        capturing.continuations[.systemAudio]?.yield(
            MeetingAudioSample(source: .systemAudio, buffer: pcm(), hostSeconds: 1))
        for _ in 0..<25 { await Task.yield() }

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(
            record.status, .ready,
            "recording + transcript + digest all completed; .partial would mislabel this as Interrupted and hide digest actions")
        XCTAssertTrue(record.audioFinalized)
        XCTAssertNil(record.youAudioPath, "the mic writer never produced a file")
        XCTAssertEqual(
            record.meetingAudioPath, "Recordings/\(record.uid)/meeting.m4a",
            "the system-audio channel finalized normally and stays untouched")
        XCTAssertEqual(
            record.errorMessage,
            "Microphone audio was not saved — the transcript is unaffected.",
            "the mismatch is surfaced, naming the exact lost channel, instead of being silently clean")

        let segments = try context.fetch(FetchDescriptor<MeetingTranscriptSegment>())
        XCTAssertEqual(segments.count, 1, "the transcript survives even though its audio did not")
        XCTAssertEqual(segments.first?.rawText, "ship it friday")
        XCTAssertEqual(segments.first?.source, .you)
    }

    func test_bothSourcesFinalize_matchingTheirTranscripts_leavesErrorMessageNil() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        capturing.continuations[.microphone]?.yield(
            MeetingAudioSample(source: .microphone, buffer: pcm(), hostSeconds: 1))
        capturing.continuations[.systemAudio]?.yield(
            MeetingAudioSample(source: .systemAudio, buffer: pcm(), hostSeconds: 1))
        for _ in 0..<25 { await Task.yield() }

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .ready)
        XCTAssertNil(record.errorMessage, "a clean recording never gets a spurious parity message")
    }

    // MARK: - Working-file cleanup after finalize (BAK-333)

    /// A clean stop finalizes both channels to real `.m4a` files — the
    /// crash-recovery scratch files (`*.partial.caf` + `recovery.json`) that
    /// made that possible are now dead weight and should be gone once
    /// `stop()` returns. The finals + playback mix must survive untouched.
    func test_stopPipeline_cleanFinalize_deletesPartialsAndManifest_keepsFinalsAndPlayback() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        capturing.continuations[.microphone]?.yield(
            MeetingAudioSample(source: .microphone, buffer: pcm(), hostSeconds: 1))
        capturing.continuations[.systemAudio]?.yield(
            MeetingAudioSample(source: .systemAudio, buffer: pcm(), hostSeconds: 1))
        for _ in 0..<25 { await Task.yield() }

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .ready)
        XCTAssertTrue(record.audioFinalized)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .youPartial, meetingUID: record.uid).path),
            "the you partial is dead weight once you.m4a is verified on disk")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .meetingPartial, meetingUID: record.uid).path),
            "the meeting partial is dead weight once meeting.m4a is verified on disk")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .recoveryManifest, meetingUID: record.uid).path),
            "every started source finalized — the manifest has nothing left to protect")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .you, meetingUID: record.uid).path),
            "the finalized you.m4a is never touched by cleanup")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .meeting, meetingUID: record.uid).path),
            "the finalized meeting.m4a is never touched by cleanup")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .playback, meetingUID: record.uid).path),
            "playback.m4a is never a working file and is never deleted")
    }

    private final class MeetingSessionAlwaysInsufficient: VoiceTranscribing, @unchecked Sendable {
        struct Overloaded: Error {}
        func readiness() async -> VoiceReadiness { .ready }
        func prepare() async throws {}
        func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error> {
            throw Overloaded()
        }
        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws {}
        func finish() async throws -> [VoiceTranscriptSegment] { [] }
        func cancel() async {}
    }

    /// Drives the real fallback transcription mode (BAK-297: the meeting
    /// session fails to start with an "insufficient resources" error, so the
    /// Meeting channel keeps RECORDING and its file is transcribed after
    /// Stop) and makes that after-Stop file transcription throw. This
    /// reaches `interrupt()` — a real, reachable failure path — AFTER the
    /// writer already finalized both channels to disk but BEFORE
    /// `stampAudioPaths`/`audioFinalized = true`/cleanup ever run.
    private func transcriptionWhoseFileFallbackFails() -> MeetingTranscriptionService {
        struct FileTranscribeFailed: Error {}
        var handed: [any VoiceTranscribing] = [StubSession(finals: []), MeetingSessionAlwaysInsufficient()]
        return MeetingTranscriptionService(
            makeSession: { handed.isEmpty ? StubSession(finals: []) : handed.removeFirst() },
            isInsufficientResources: { $0 is MeetingSessionAlwaysInsufficient.Overloaded },
            transcribeFile: { _ in throw FileTranscribeFailed() })
    }

    /// Crash safety must not regress: an interrupted stop leaves every
    /// working file exactly where it was — cleanup only ever runs after a
    /// fully successful finalize.
    func test_stopPipeline_interruptedAfterAudioFinalizes_leavesPartialsAndManifestIntact() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcriptionWhoseFileFallbackFails())
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        capturing.continuations[.microphone]?.yield(
            MeetingAudioSample(source: .microphone, buffer: pcm(), hostSeconds: 1))
        capturing.continuations[.systemAudio]?.yield(
            MeetingAudioSample(source: .systemAudio, buffer: pcm(), hostSeconds: 1))
        for _ in 0..<25 { await Task.yield() }

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(
            record.status, .partial,
            "the after-Stop file transcription failed — the meeting is interrupted, not ready")
        XCTAssertFalse(record.audioFinalized, "cleanup's gate never flipped")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .youPartial, meetingUID: record.uid).path),
            "interrupted before cleanup ran — the partial survives")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .meetingPartial, meetingUID: record.uid).path),
            "interrupted before cleanup ran — the partial survives")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: .recoveryManifest, meetingUID: record.uid).path),
            "interrupted before cleanup ran — the manifest survives")
    }

    /// The one-off launch sweep (BAK-333): a meeting that finalized before
    /// this cleanup existed is already `.ready`/`audioFinalized` but still
    /// has its manifest and finalized partials sitting on disk. Launch
    /// recovery must clean those up WITHOUT touching the record's status —
    /// promoting an already-`ready` meeting to `.partial` would be wrong.
    func test_recoverOnLaunch_cleansUpLeftoverWorkingFiles_forAnAlreadyReadyRecord() async throws {
        let context = try ctx()
        let uid = "already-ready-meeting"
        try store.createMeetingDirectory(forMeetingUID: uid)

        let record = MeetingRecord(title: "Old standup")
        record.uid = uid
        record.status = .ready
        record.audioFinalized = true
        record.captureSources = ["microphone", "systemAudio"]
        record.youAudioPath = "Recordings/\(uid)/you.m4a"
        record.meetingAudioPath = "Recordings/\(uid)/meeting.m4a"
        context.insert(record)
        try context.save()

        // The finalized tracks + the leftover crash-recovery scratch files —
        // exactly the ~285 MB-per-meeting shape from the real incident.
        try Data("final".utf8).write(to: store.fileURL(for: .you, meetingUID: uid))
        try Data("final".utf8).write(to: store.fileURL(for: .meeting, meetingUID: uid))
        try Data("partial".utf8).write(to: store.fileURL(for: .youPartial, meetingUID: uid))
        try Data("partial".utf8).write(to: store.fileURL(for: .meetingPartial, meetingUID: uid))
        let manifest = MeetingRecoveryManifest(
            meetingUID: uid,
            relativeDirectory: "Recordings/\(uid)",
            sources: [
                .init(fileName: "you.partial.caf", safeByteOffset: 7, safeSampleOffset: 4800),
                .init(fileName: "meeting.partial.caf", safeByteOffset: 7, safeSampleOffset: 4800),
            ],
            startedAt: t0,
            lastState: .ready)
        try manifest.writeAtomically(to: store.fileURL(for: .recoveryManifest, meetingUID: uid))

        let coordinator = makeCoordinator(context: context, capturing: StubCapturing())
        coordinator.recoverOnLaunch()

        let reloaded = try XCTUnwrap(try records(in: context).first { $0.uid == uid })
        XCTAssertEqual(reloaded.status, .ready, "an already-ready meeting is never demoted to partial")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try store.fileURL(for: .youPartial, meetingUID: uid).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try store.fileURL(for: .meetingPartial, meetingUID: uid).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try store.fileURL(for: .recoveryManifest, meetingUID: uid).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try store.fileURL(for: .you, meetingUID: uid).path),
            "the launch sweep never touches finalized audio")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try store.fileURL(for: .meeting, meetingUID: uid).path),
            "the launch sweep never touches finalized audio")
    }

    // MARK: - Failures

    func test_noPermittedSources_failsWithoutCreatingARecord() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        capturing.available = []
        let coordinator = makeCoordinator(context: context, capturing: capturing)

        await coordinator.requestStart(title: "Standup")

        guard case .failed = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertNil(coordinator.pendingConfirmation)
        XCTAssertEqual(try records(in: context).count, 0)
    }

    func test_missingSystemAudio_asksForDegradedConfirmation_thenRecordsMicOnly() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        capturing.available = [.microphone]
        let coordinator = makeCoordinator(context: context, capturing: capturing)

        await coordinator.requestStart(title: "Standup")

        guard case .degraded(let available, let missing) = coordinator.pendingConfirmation else {
            return XCTFail("expected degraded confirmation, got \(String(describing: coordinator.pendingConfirmation))")
        }
        XCTAssertEqual(available, [.microphone])
        XCTAssertEqual(missing, [.systemAudio])

        await coordinator.confirmStart(sources: [.microphone])

        XCTAssertEqual(coordinator.state, .recording(startedAt: t0))
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.captureSources, ["microphone"])
    }

    func test_writerCreationFailure_failsAndPersistsTheReason() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(context: context, capturing: capturing, writerThrows: true)
        await coordinator.requestStart(title: "Standup")

        await coordinator.confirmStart(sources: [.microphone])

        guard case .failed = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertNotNil(record.errorMessage, "disk failures persist their reason")
        XCTAssertTrue(capturing.started.isEmpty, "no capture runs without a writer")
    }

    func test_sourceFailureMidRecording_pausesThatSourceOnly_andKeepsRecording() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(context: context, capturing: capturing)
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        capturing.continuations[.systemAudio]?.finish(throwing: VoiceSessionError.audioFormatUnavailable)
        for _ in 0..<25 { await Task.yield() }

        guard case .paused = coordinator.sourceState(.systemAudio) else {
            return XCTFail("expected systemAudio paused, got \(coordinator.sourceState(.systemAudio))")
        }
        XCTAssertEqual(coordinator.sourceState(.microphone), .streaming)
        XCTAssertEqual(coordinator.state, .recording(startedAt: t0), "one source failing never kills the meeting")
    }

    // MARK: - Digest generation (Task 8 wiring)

    private func digestResult(evidence: [String]) -> MeetingDigest {
        MeetingDigest(
            summary: "We planned the release.",
            decisions: ["Ship Friday"],
            unresolvedQuestions: [],
            actions: [.init(
                title: "Ship the release", owner: "me", due: nil,
                evidenceSegmentIDs: evidence)],
            promptVersion: "voice-core-1",
            osBuild: "27A5194q")
    }

    func test_stopPipeline_runsTheDigest_andCreatesPendingProposals() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let you = seg("y1", "ship it friday")
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [you]),
            digest: { segments, _ in
                .success(self.digestResult(
                    evidence: segments.map { MeetingTranscriptMerge.persistentID(for: $0) }))
            })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestStatus, .ready)
        XCTAssertEqual(record.summaryText, "We planned the release.")
        XCTAssertEqual(record.decisions, ["Ship Friday"])
        let proposals = try context.fetch(FetchDescriptor<MeetingActionProposal>())
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.state, .pending, "every proposal is approval-gated")
        XCTAssertEqual(proposals.first?.supportingSegmentUIDs, ["microphone:y1"])
        XCTAssertEqual(record.promptVersion, "voice-core-1")
    }

    func test_digestFailure_isRetryable_withoutDegradingTheMeeting() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        var digestWorks = false
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]),
            digest: { segments, _ in
                digestWorks
                    ? .success(self.digestResult(
                        evidence: segments.map { MeetingTranscriptMerge.persistentID(for: $0) }))
                    : .failure(.model(.modelNotReady))
            })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])
        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.status, .ready, "a digest failure never degrades the recording")
        XCTAssertEqual(record.digestStatus, .failed)

        digestWorks = true
        await coordinator.retryDigest(for: record)

        XCTAssertEqual(record.digestStatus, .ready)
        XCTAssertEqual(record.summaryText, "We planned the release.")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MeetingActionProposal>()).count, 1,
            "the retry reads the persisted transcript back")
    }

    // MARK: - Digest failure reason + partial degradation (BAK-330, BAK-331)

    func test_digestFailure_persistsTheMappedReason() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]),
            digest: { _, _ in .failure(.model(.deviceNotEligible)) })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestStatus, .failed)
        XCTAssertEqual(
            record.digestFailureReason, .deviceNotEligible,
            "the failure reason is mapped and persisted alongside .failed")
    }

    func test_digestRetry_thatFails_persistsTheNewMappedReason() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        var failure: LocalModelFailure = .modelNotReady
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]),
            digest: { _, _ in .failure(.model(failure)) })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])
        await coordinator.stop()
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestFailureReason, .modelNotReady)

        failure = .contextOverflow
        await coordinator.retryDigest(for: record)

        XCTAssertEqual(record.digestStatus, .failed)
        XCTAssertEqual(
            record.digestFailureReason, .contextOverflow,
            "a retry that fails differently updates the persisted reason")
    }

    func test_successfulDigest_clearsAPreviouslyPersistedFailureReason() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        var digestWorks = false
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [seg("y1", "ship it friday")]),
            digest: { segments, _ in
                digestWorks
                    ? .success(self.digestResult(
                        evidence: segments.map { MeetingTranscriptMerge.persistentID(for: $0) }))
                    : .failure(.model(.appleIntelligenceDisabled))
            })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])
        await coordinator.stop()
        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestFailureReason, .appleIntelligenceDisabled)

        digestWorks = true
        await coordinator.retryDigest(for: record)

        XCTAssertEqual(record.digestStatus, .ready)
        XCTAssertNil(record.digestFailureReason, "a successful retry clears the stale reason")
    }

    func test_digestWithOmittedSpans_persistsPartialStatus_andAnOmissionNote() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let you = seg("y1", "ship it friday")
        var partial = digestResult(evidence: [MeetingTranscriptMerge.persistentID(for: you)])
        partial.omittedSpans = [852.0...1143.0]
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [you]),
            digest: { _, _ in .success(partial) })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestStatus, .partial, "an omitted span degrades ready to partial")
        XCTAssertEqual(record.summaryText, "We planned the release.", "the surviving content still lands")
        XCTAssertEqual(
            record.digestOmissionNote,
            "14:12–19:03 into the meeting could not be summarised.")
        XCTAssertNil(record.digestFailureReason, "a partial digest is a success, not a failure")
    }

    func test_digestWithNoOmittedSpans_persistsReadyStatus_withNoOmissionNote() async throws {
        let context = try ctx()
        let capturing = StubCapturing()
        let you = seg("y1", "ship it friday")
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [you]),
            digest: { segments, _ in
                .success(self.digestResult(
                    evidence: segments.map { MeetingTranscriptMerge.persistentID(for: $0) }))
            })
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone])

        await coordinator.stop()

        let record = try XCTUnwrap(try records(in: context).first)
        XCTAssertEqual(record.digestStatus, .ready)
        XCTAssertNil(record.digestOmissionNote)
    }

    // MARK: - Speaker attribution (BAK-335)

    /// A scripted handoff transcript on the MEETING channel, with a past
    /// proposal owner ("Fahad") as the only known candidate: the handoff
    /// line stays with the previous (unattributed) speaker, the span after
    /// it is attributed, and the "you" channel is never auto-stamped.
    func test_finalize_stampsSpeakersOnMeetingChannelRows_fromScriptedHandoffs() async throws {
        let context = try ctx()
        let pastMeeting = MeetingRecord(title: "Old standup")
        context.insert(pastMeeting)
        let pastProposal = MeetingActionProposal(title: "Ping Thales", owner: "Fahad")
        pastProposal.meeting = pastMeeting
        context.insert(pastProposal)
        try context.save()

        let capturing = StubCapturing()
        let you = seg("y1", "quick note", source: .microphone, start: 0, end: 1)
        // Gaps between segments are >= the 1.5s pause threshold so each
        // stays its own utterance after merging (BAK-335 FINDING 3) --
        // matching a realistic handoff pause, not word-level fragments.
        let m1 = seg("m1", "let's start", source: .meeting, start: 0, end: 1)
        let m2 = seg("m2", "over to Fahad", source: .meeting, start: 2.6, end: 3.6)
        let m3 = seg("m3", "shipped the release", source: .meeting, start: 5.2, end: 6.2)
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(youFinals: [you], meetingFinals: [m1, m2, m3]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        await coordinator.stop()

        let segments = try context.fetch(FetchDescriptor<MeetingTranscriptSegment>())
        let byRaw = Dictionary(uniqueKeysWithValues: segments.map { ($0.rawText, $0) })
        XCTAssertNil(byRaw["let's start"]?.speaker, "before any handoff — unattributed")
        XCTAssertNil(byRaw["over to Fahad"]?.speaker, "the handoff line itself stays with the previous speaker")
        XCTAssertEqual(byRaw["shipped the release"]?.speaker, "Fahad", "the span AFTER the matched handoff")
        XCTAssertNil(byRaw["quick note"]?.speaker, "the you channel is never auto-stamped")
    }

    func test_retryDigest_threadsSpeakerThroughTranscriptSegmentReconstruction() async throws {
        let context = try ctx()
        let pastMeeting = MeetingRecord(title: "Old standup")
        context.insert(pastMeeting)
        let pastProposal = MeetingActionProposal(title: "Ping Thales", owner: "Fahad")
        pastProposal.meeting = pastMeeting
        context.insert(pastProposal)
        try context.save()

        let capturing = StubCapturing()
        // Gap >= the 1.5s pause threshold so the two stay separate
        // utterances after merging (BAK-335 FINDING 3).
        let m1 = seg("m1", "over to Fahad", source: .meeting, start: 0, end: 1)
        let m2 = seg("m2", "shipped the release", source: .meeting, start: 2.6, end: 3.6)
        final class Capture: @unchecked Sendable { var seen: [VoiceTranscriptSegment] = [] }
        let captured = Capture()
        // First pass with NO digest closure — digestStatus lands on
        // .pending, which is what makes retryDigest's guard actually run
        // (a coordinator that already succeeded at digest during stop()
        // would leave digestStatus == .ready and retryDigest would no-op).
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(meetingFinals: [m1, m2]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])
        await coordinator.stop()
        // Two MeetingRecords now exist (the past one + this one) — find THIS
        // meeting by title, not just `.first`, since fetch order isn't
        // guaranteed to put the newest record first.
        let record = try XCTUnwrap(try records(in: context).first { $0.title == "Standup" })
        XCTAssertEqual(record.digestStatus, .pending)

        // A second coordinator over the SAME context/record, now WITH the
        // capturing digest closure, drives retryDigest.
        let retryCoordinator = makeCoordinator(
            context: context, capturing: StubCapturing(),
            digest: { segments, _ in
                captured.seen = segments
                return .success(self.digestResult(evidence: []))
            })
        await retryCoordinator.retryDigest(for: record)

        let bySpeakerlessText = Dictionary(uniqueKeysWithValues: captured.seen.map { ($0.text, $0.speaker) })
        XCTAssertNil(bySpeakerlessText["over to Fahad"] ?? nil)
        XCTAssertEqual(bySpeakerlessText["shipped the release"] ?? nil, "Fahad")
    }

    /// FINDING 3 (review, effectiveness gap): real meeting-channel segments
    /// are near-word-level (~15 chars), so a handoff phrase routinely spans
    /// 2-3 raw segments — attributing over RAW per-segment text would never
    /// match "pass it back to Alex" split as "pass it" / "back to" /
    /// "Alex.". The coordinator must merge into utterances FIRST (the same
    /// 1.5s-pause, same-source rule `MeetingUtteranceMerge` already uses)
    /// and attribute over utterance text, then stamp every CONSTITUENT
    /// segment of an attributed utterance, not just one.
    func test_finalize_mergesWordLevelFragmentsBeforeAttribution_stampsEveryConstituent() async throws {
        let context = try ctx()
        let pastMeeting = MeetingRecord(title: "Old standup")
        context.insert(pastMeeting)
        let pastProposal = MeetingActionProposal(title: "Ping Thales", owner: "Alex")
        pastProposal.meeting = pastMeeting
        context.insert(pastProposal)
        try context.save()

        let capturing = StubCapturing()
        // The handoff phrase chopped into near-word-level fragments, each
        // well within the 1.5s pause threshold of its neighbor so they
        // merge into ONE utterance whose combined text is
        // "pass it back to Alex." -- matching the "pass it (back )?to X"
        // pattern only once merged.
        let f1 = seg("m1", "pass it", source: .meeting, start: 0.0, end: 0.4)
        let f2 = seg("m2", "back to", source: .meeting, start: 0.5, end: 0.9)
        let f3 = seg("m3", "Alex.", source: .meeting, start: 1.0, end: 1.3)
        // A real pause (>= 1.5s) before the response, itself also
        // fragmented, so this test proves BOTH sides of the merge.
        let f4 = seg("m4", "I shipped", source: .meeting, start: 3.0, end: 3.4)
        let f5 = seg("m5", "the release", source: .meeting, start: 3.5, end: 3.9)
        let coordinator = makeCoordinator(
            context: context, capturing: capturing,
            transcription: transcription(meetingFinals: [f1, f2, f3, f4, f5]))
        await coordinator.requestStart(title: "Standup")
        await coordinator.confirmStart(sources: [.microphone, .systemAudio])

        await coordinator.stop()

        let segments = try context.fetch(FetchDescriptor<MeetingTranscriptSegment>())
        let byRaw = Dictionary(uniqueKeysWithValues: segments.map { ($0.rawText, $0) })
        XCTAssertNil(byRaw["pass it"]?.speaker, "the handoff utterance itself stays with the previous (unattributed) speaker")
        XCTAssertNil(byRaw["back to"]?.speaker)
        XCTAssertNil(byRaw["Alex."]?.speaker)
        XCTAssertEqual(byRaw["I shipped"]?.speaker, "Alex", "every constituent of the attributed utterance is stamped")
        XCTAssertEqual(byRaw["the release"]?.speaker, "Alex", "not just the first constituent")
    }

    // MARK: - Recovery on launch

    func test_recoveryOnLaunch_surfacesDiscoverablePartials() async throws {
        let context = try ctx()
        // A crash left durable partials + a manifest behind.
        let uid = "crashed-meeting"
        try store.createMeetingDirectory(forMeetingUID: uid)
        let manifest = MeetingRecoveryManifest(
            meetingUID: uid,
            relativeDirectory: "Recordings/\(uid)",
            sources: [.init(fileName: "you.partial.caf", safeByteOffset: 1024, safeSampleOffset: 4800)],
            startedAt: t0,
            lastState: .recording(startedAt: t0))
        try manifest.writeAtomically(
            to: store.fileURL(for: .recoveryManifest, meetingUID: uid))

        let coordinator = makeCoordinator(context: context, capturing: StubCapturing())
        coordinator.recoverOnLaunch()

        let record = try XCTUnwrap(
            try records(in: context).first { $0.uid == uid },
            "a crash leaves a DISCOVERABLE partial meeting")
        XCTAssertEqual(record.status, .partial)
        XCTAssertEqual(record.startedAt, t0)
    }
}
