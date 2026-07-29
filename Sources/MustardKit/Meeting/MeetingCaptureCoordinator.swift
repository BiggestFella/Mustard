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
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.capturing = capturing
        self.store = store
        self.makeWriter = makeWriter
        self.transcription = transcription
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
            return fail("Could not check audio permissions: \(error.localizedDescription)")
        }
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
            try await transcription.start()

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
        } catch {
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

        await capture?.stop()
        capture = nil
        transcriptionFeed?.finish()
        transcriptionFeed = nil
        await transcriptionPump?.value
        transcriptionPump = nil

        guard let record = activeMeeting else { return }
        do {
            try await writer?.finalizeSources()
        } catch {
            return interrupt(record, reason: "Audio finalization failed: \(error.localizedDescription)")
        }
        apply(.audioFinalized)

        let segments: [VoiceTranscriptSegment]
        do {
            let meetingFile = try? store.fileURL(for: .meeting, meetingUID: record.uid)
            let hasMeetingTrack = meetingFile.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            segments = try await transcription.stop(
                meetingAudioFile: hasMeetingTrack ? meetingFile : nil)
        } catch {
            return interrupt(record, reason: "Transcription failed: \(error.localizedDescription)")
        }
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
        stampAudioPaths(on: record)
        record.audioFinalized = true
        // Digest generation is Task 7 — until then the meeting is reviewable
        // raw, with the digest explicitly pending.
        apply(.digestReady)
        record.digestStatus = .pending
        record.endedAt = now()
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
