import Foundation
import SwiftData
import Observation
import AVFoundation

/// The manual meeting recorder (Meetings Task 6, BAK-298): sequences consent
/// → record creation → writers/capture/transcription → stop → finalization →
/// transcript persistence, driving every transition through the pure
/// `MeetingRecordingState` machine and saving the record before and after
/// each impure edge. Recording is explicit (never without confirmation),
/// local, recoverable, and never silently degraded.
@MainActor
@Observable
public final class MeetingCaptureCoordinator {
    /// What the consent prompt offers before anything records.
    public enum StartConfirmation: Equatable, Sendable {
        /// Everything requested is available — consent still required.
        case consent(sources: [MeetingAudioSource])
        /// Some sources are unavailable; recording would be degraded and the
        /// user must explicitly accept that.
        case degraded(available: [MeetingAudioSource], missing: [MeetingAudioSource])
    }

    public private(set) var state: MeetingRecordingState = .idle
    public private(set) var activeMeeting: MeetingRecord?
    public private(set) var pendingConfirmation: StartConfirmation?

    private let context: ModelContext
    private let capturing: any MeetingAudioCapturing
    private let store: MeetingAudioStore
    private let makeWriter: (String, Date) throws -> MeetingAudioWriter
    private let transcription: MeetingTranscriptionService
    /// Digest generation seam (Task 7's service; nil = no digest step). A
    /// digest failure never degrades the recording — it marks the digest
    /// failed and retryable.
    private let generateDigest: ((_ segments: [VoiceTranscriptSegment], _ now: Date) async -> Result<MeetingDigest, MeetingDigestFailure>)?
    private let now: () -> Date

    private var pendingTitle = ""
    private var writer: MeetingAudioWriter?
    private var capture: MeetingAudioCapture?
    private var transcriptionFeed: AsyncStream<(MeetingSegmentSource, MeetingAudioSample)>.Continuation?
    private var transcriptionPump: Task<Void, Never>?

    public init(
        context: ModelContext,
        capturing: any MeetingAudioCapturing,
        store: MeetingAudioStore,
        makeWriter: @escaping (String, Date) throws -> MeetingAudioWriter,
        transcription: MeetingTranscriptionService,
        generateDigest: ((_ segments: [VoiceTranscriptSegment], _ now: Date) async -> Result<MeetingDigest, MeetingDigestFailure>)? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.capturing = capturing
        self.store = store
        self.makeWriter = makeWriter
        self.transcription = transcription
        self.generateDigest = generateDigest
        self.now = now
    }

    // MARK: - Lifecycle

    /// Start Meeting: check availability and raise the consent prompt.
    /// Nothing records here — only `confirmStart` (the explicit user action)
    /// may begin capture.
    public func requestStart(title: String) async {
        guard state == .idle else { return }   // duplicate prevention
        pendingTitle = title
        apply(.prepare)

        let available: [MeetingAudioSource]
        do {
            available = try await capturing.availableSources()
        } catch {
            voiceLog.notice("meeting: availableSources threw \(String(describing: error), privacy: .public)")
            return fail("Could not check audio permissions: \(error.localizedDescription)")
        }
        voiceLog.notice(
            "meeting: available=\(available.map(\.rawValue).joined(separator: ","), privacy: .public)")
        guard !available.isEmpty else {
            return fail("No audio source is permitted — grant the microphone and Screen & System Audio Recording in Voice Setup.")
        }
        switch MeetingAudioCapture.startDecision(
            requested: [.microphone, .systemAudio], available: available
        ) {
        case .start(let sources):
            pendingConfirmation = .consent(sources: sources)
        case .needsConfirmation(let missing):
            pendingConfirmation = .degraded(available: available, missing: missing)
        }
    }

    /// The consent gate: create and save the record BEFORE any impure edge,
    /// then writer → transcription → capture, and only then the machine's
    /// `userConfirmedStart`.
    public func confirmStart(sources: [MeetingAudioSource]) async {
        guard state == .preparing, pendingConfirmation != nil, !sources.isEmpty else { return }
        pendingConfirmation = nil
        let startedAt = now()

        let record = MeetingRecord(title: pendingTitle)
        record.startedAt = startedAt
        record.captureSources = sources.map(\.rawValue).sorted()
        context.insert(record)
        try? context.save()
        activeMeeting = record

        do {
            let writer = try makeWriter(record.uid, startedAt)
            self.writer = writer
            try await transcription.start(sources: sources)

            let (feed, continuation) = AsyncStream.makeStream(
                of: (MeetingSegmentSource, MeetingAudioSample).self)
            transcriptionFeed = continuation
            // ONE serial pump keeps transcription appends in arrival order;
            // the writer appends inline (synchronous, ordered by the route).
            transcriptionPump = Task { [transcription] in
                for await (channel, sample) in feed {
                    try? await transcription.append(sample.buffer, channel: channel)
                }
            }
            let capture = MeetingAudioCapture(capturing: capturing) { [weak self] channel, sample in
                try? self?.writer?.append(sample.buffer, to: channel)
                self?.transcriptionFeed?.yield((channel, sample))
            }
            try await capture.start(sources: sources)
            self.capture = capture
            apply(.userConfirmedStart(at: startedAt))
            voiceLog.notice(
                "meeting: recording uid=\(record.uid, privacy: .public) sources=\(sources.map(\.rawValue).joined(separator: ","), privacy: .public)")
        } catch {
            voiceLog.notice("meeting: start failed \(String(describing: error), privacy: .public)")
            fail("Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Dismiss the consent prompt without recording anything.
    public func cancelStart() {
        guard state == .preparing else { return }
        pendingConfirmation = nil
        state = .idle
    }

    public func pause() async {
        guard case .recording = state else { return }
        try? await capturing.pause()
        apply(.pause)
    }

    public func resume() async {
        guard state == .paused else { return }
        try? await capturing.resume()
        apply(.resume(at: now()))
    }

    /// Stop: finalize audio, transcribe (dual-live or file fallback), persist
    /// segments and validated relative paths, and ready the record. Any
    /// finalization failure preserves the partials as an interrupted meeting.
    public func stop() async {
        switch state {
        case .recording, .paused: break
        default: return
        }
        apply(.stop)

        voiceLog.notice("meeting: stop entered, awaiting capture.stop")
        await capture?.stop()
        capture = nil
        voiceLog.notice("meeting: capture stopped, draining transcription pump")
        transcriptionFeed?.finish()
        transcriptionFeed = nil
        await transcriptionPump?.value
        transcriptionPump = nil
        voiceLog.notice("meeting: pump drained, finalizing audio sources")

        guard let record = activeMeeting else { return }
        do {
            try await writer?.finalizeSources()
        } catch {
            voiceLog.notice("meeting: finalizeSources threw \(String(describing: error), privacy: .public)")
            return interrupt(record, reason: "Audio finalization failed: \(error.localizedDescription)")
        }
        apply(.audioFinalized)
        voiceLog.notice("meeting: audio finalized, awaiting transcription.stop")

        let segments: [VoiceTranscriptSegment]
        do {
            let meetingFile = try? store.fileURL(for: .meeting, meetingUID: record.uid)
            let hasMeetingTrack = meetingFile.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            segments = try await transcription.stop(
                meetingAudioFile: hasMeetingTrack ? meetingFile : nil)
        } catch {
            voiceLog.notice("meeting: transcription.stop threw \(String(describing: error), privacy: .public)")
            return interrupt(record, reason: "Transcription failed: \(error.localizedDescription)")
        }
        voiceLog.notice("meeting: transcript segments=\(segments.count, privacy: .public)")
        for segment in segments {
            let persisted = MeetingTranscriptSegment(
                rawText: segment.text,
                source: segment.source == .meeting ? .meeting : .you,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: segment.confidence)
            persisted.uid = MeetingTranscriptMerge.persistentID(for: segment)
            persisted.meeting = record
            context.insert(persisted)
        }
        apply(.transcriptFinalized)

        // Mix is best-effort; the finalized source tracks are the truth.
        try? await writer?.mixPlayback()
        writer = nil
        voiceLog.notice("meeting: mix done, recording complete")
        stampAudioPaths(on: record)
        record.audioFinalized = true

        // Digest (Task 7's service): success fills summary + proposals; any
        // failure is marked retryable and never degrades the recording.
        if let generateDigest {
            record.digestStatus = .generating
            try? context.save()
            switch await generateDigest(segments, now()) {
            case .success(let digest): applyDigest(digest, to: record)
            case .failure: record.digestStatus = .failed
            }
        } else {
            record.digestStatus = .pending
        }
        apply(.digestReady)
        record.endedAt = now()
        try? context.save()
    }

    /// Re-run digest generation for a finished meeting whose digest failed
    /// (or was never generated) — reads the persisted transcript back,
    /// preferring user corrections over raw text.
    public func retryDigest(for record: MeetingRecord) async {
        guard let generateDigest, record.status == .ready,
              record.digestStatus == .failed || record.digestStatus == .pending else { return }
        record.digestStatus = .generating
        try? context.save()
        let segments = (record.segments ?? [])
            .sorted { ($0.startSeconds, $0.uid) < ($1.startSeconds, $1.uid) }
            .map(Self.transcriptSegment(from:))
        switch await generateDigest(segments, now()) {
        case .success(let digest): applyDigest(digest, to: record)
        case .failure: record.digestStatus = .failed
        }
        try? context.save()
    }

    public func sourceState(_ source: MeetingAudioSource) -> MeetingAudioCapture.SourceState {
        capture?.state(of: source) ?? .idle
    }

    /// Return to idle after a terminal state so the next meeting can start.
    public func reset() {
        switch state {
        case .ready, .failed, .partial: break
        default: return
        }
        state = .idle
        activeMeeting = nil
        pendingConfirmation = nil
    }

    /// Surface crash-left partial meetings on launch: every discoverable
    /// recovery manifest becomes (or updates) a `.partial` record.
    public func recoverOnLaunch() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: store.recordingsRoot, includingPropertiesForKeys: nil) else { return }
        let existing = (try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        for directory in directories {
            let manifestURL = directory.appendingPathComponent(
                MeetingAudioFile.recoveryManifest.rawValue)
            guard let manifest = try? MeetingRecoveryManifest.read(from: manifestURL) else {
                continue
            }
            let record = existing.first { $0.uid == manifest.meetingUID } ?? {
                let created = MeetingRecord(title: "Recovered meeting")
                created.uid = manifest.meetingUID
                context.insert(created)
                return created
            }()
            // A finished meeting's manifest is just a leftover; only meetings
            // that never reached ready are surfaced as partial.
            guard record.status != .ready else { continue }
            record.status = .partial
            record.startedAt = manifest.startedAt
            record.errorMessage = "Recording was interrupted — the safely written audio survives."
        }
        try? context.save()
    }

    // MARK: - Internals

    /// Every legal transition goes through the pure machine; each one is
    /// persisted immediately (save before/after impure edges).
    private func apply(_ event: MeetingRecordingEvent) {
        guard let next = state.applying(event) else { return }
        state = next
        if let record = activeMeeting {
            record.status = Self.persistedStatus(for: next) ?? record.status
            try? context.save()
        }
    }

    private func fail(_ reason: String) {
        if let next = state.applying(.fail(reason: reason)) { state = next }
        pendingConfirmation = nil
        if let record = activeMeeting {
            record.status = .failed
            record.errorMessage = reason
            try? context.save()
        }
    }

    private func interrupt(_ record: MeetingRecord, reason: String) {
        if let next = state.applying(.interrupted(reason: reason)) { state = next }
        record.status = .partial
        record.errorMessage = reason
        try? context.save()
    }

    /// Land a validated digest: summary/decisions/questions on the record,
    /// pending proposals replaced (approved/rejected ones are Leon's history
    /// and stay), traceability stamped.
    private func applyDigest(_ digest: MeetingDigest, to record: MeetingRecord) {
        record.summaryText = digest.summary
        record.decisions = digest.decisions
        record.unresolvedQuestions = digest.unresolvedQuestions
        record.promptVersion = digest.promptVersion
        record.osBuild = digest.osBuild
        for old in record.proposals ?? [] where old.state == .pending {
            context.delete(old)
        }
        for action in digest.actions {
            let proposal = MeetingActionProposal(
                title: action.title,
                owner: action.owner,
                scheduledFor: action.due,
                supportingSegmentUIDs: action.evidenceSegmentIDs)
            proposal.meeting = record
            context.insert(proposal)
        }
        record.digestStatus = .ready
        try? context.save()
    }

    /// Rebuild a transcript segment from its persisted row. The persisted uid
    /// is the source-namespaced persistent id; stripping the namespace keeps
    /// `MeetingTranscriptMerge.persistentID` reproducing it exactly (evidence
    /// validation depends on that round trip). Corrections win over raw text
    /// for digestion; the raw text remains untouched evidence.
    static func transcriptSegment(from persisted: MeetingTranscriptSegment) -> VoiceTranscriptSegment {
        let source: VoiceAudioSource = persisted.source == .meeting ? .meeting : .microphone
        let namespace = source.rawValue + ":"
        let rawID = persisted.uid.hasPrefix(namespace)
            ? String(persisted.uid.dropFirst(namespace.count))
            : persisted.uid
        return VoiceTranscriptSegment(
            id: rawID,
            text: persisted.correctedText ?? persisted.rawText,
            startSeconds: persisted.startSeconds,
            endSeconds: persisted.endSeconds,
            isFinal: true,
            confidence: persisted.confidence,
            source: source)
    }

    private func stampAudioPaths(on record: MeetingRecord) {
        func relative(_ file: MeetingAudioFile) -> String? {
            guard let url = try? store.fileURL(for: file, meetingUID: record.uid),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MeetingRecord.validatedRelativeAudioPath(
                "Recordings/\(record.uid)/\(file.rawValue)")
        }
        record.youAudioPath = relative(.you)
        record.meetingAudioPath = relative(.meeting)
        record.playbackAudioPath = relative(.playback)
    }

    /// The persisted (CloudKit-shaped) status for a machine state; nil keeps
    /// the record's current value (transient states the store doesn't model).
    private static func persistedStatus(for state: MeetingRecordingState) -> MeetingStatus? {
        switch state {
        case .idle: nil
        case .preparing: .preparing
        case .recording, .paused: .recording
        case .finalizingAudio, .finalizingTranscript, .summarizing: .finalizing
        case .ready: .ready
        case .partial: .partial
        case .failed: .failed
        }
    }
}
