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
        youFinals: [VoiceTranscriptSegment] = []
    ) -> MeetingTranscriptionService {
        var handed = [
            StubSession(finals: youFinals),
            StubSession(finals: []),
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

    private func seg(_ id: String, _ text: String) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: 0, endSeconds: 1,
            isFinal: true, confidence: nil, source: .microphone)
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
