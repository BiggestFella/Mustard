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
    /// BAK-332: channels whose writer-append failure has already been logged
    /// this recording — logs once per channel rather than once per buffer.
    /// Reset at the start of each `confirmStart`.
    private var writerFailureLogged: Set<MeetingSegmentSource> = []

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
            writerFailureLogged = []
            // BAK-334: contextual vocabulary (areas, task lists, recent task
            // titles, past meeting-action owners, plus any custom terms)
            // computed once per meeting start — never per buffer.
            let lexicon = VoiceLexiconSource.fetch(
                context: context, now: startedAt, userTerms: VoiceLexiconUserTerms.load())
            try await transcription.start(sources: sources, lexicon: lexicon)

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
            // BAK-332: a writer-append failure used to vanish behind `try?`
            // while the very same buffer kept flowing into transcription —
            // the mechanism behind an incident where 413 "you" transcript
            // segments persisted with zero mic bytes ever written to disk.
            // Surface it once per channel; `MeetingSourceParity` at finalize
            // is what gives the loss a visible, user-facing consequence —
            // this log is the earliest signal, not the only one.
            let capture = MeetingAudioCapture(capturing: capturing) { [weak self] channel, sample in
                guard let self else { return }
                do {
                    try self.writer?.append(sample.buffer, to: channel)
                } catch {
                    if self.writerFailureLogged.insert(channel).inserted {
                        voiceLog.error(
                            "meeting: writer append failed channel=\(channel.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                }
                self.transcriptionFeed?.yield((channel, sample))
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
        let speakerByID = Self.attributedSpeakers(for: segments, context: context)
        for segment in segments {
            let persisted = MeetingTranscriptSegment(
                rawText: segment.text,
                source: segment.source == .meeting ? .meeting : .you,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: segment.confidence)
            persisted.uid = MeetingTranscriptMerge.persistentID(for: segment)
            persisted.speaker = speakerByID[persisted.uid]
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
        // The finalized state must be durable BEFORE the recovery manifest
        // is deleted — a crash between the two would otherwise strand the
        // meeting at "Finishing…" forever, since recoverOnLaunch discovers
        // work solely by scanning for manifests.
        try? context.save()
        cleanUpWorkingFiles(for: record)

        // BAK-332: the audio/transcript parity check — the actual fix for
        // the incident. Before this, a source could produce hundreds of
        // real transcript segments while its writer silently never wrote a
        // file, and NOTHING compared the two: the meeting still finalized
        // `ready`/`audioFinalized = true`. Recording, transcript and digest
        // all stay untouched either way; a mismatch only ever adds a
        // user-visible `errorMessage` naming the lost channel(s).
        applySourceParity(segments: segments, to: record)

        // Digest (Task 7's service): success fills summary + proposals; any
        // failure is marked retryable and never degrades the recording.
        if let generateDigest {
            record.digestStatus = .generating
            try? context.save()
            switch await generateDigest(segments, now()) {
            case .success(let digest): applyDigest(digest, to: record)
            case .failure(let failure): applyDigestFailure(failure, to: record)
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
        case .failure(let failure): applyDigestFailure(failure, to: record)
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
            // BAK-333: a meeting that already finished (`ready` +
            // `audioFinalized`) has a manifest here for one reason only — it
            // finalized before this cleanup existed, or a prior cleanup pass
            // never completed. Either way it is a pure leftover: sweep its
            // working files now and never touch its status. A finished
            // meeting is never promoted (back) to partial.
            if record.status == .ready, record.audioFinalized {
                cleanUpWorkingFiles(for: record)
                continue
            }
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
    /// and stay), traceability stamped. BAK-330: any omitted transcript span
    /// degrades the digest to `.partial` (still real content) instead of
    /// `.ready`. BAK-331: success always clears a stale failure reason.
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
        record.digestOmissionNote = MeetingDigest.omissionNote(spans: digest.omittedSpans)
        record.digestFailureReason = nil
        record.digestStatus = digest.omittedSpans.isEmpty ? .ready : .partial
        try? context.save()
    }

    /// Land a digest failure: map it to a persistable, user-facing reason
    /// (BAK-331) and log the reason's rawValue only — never the raw model
    /// error or any transcript content.
    private func applyDigestFailure(_ failure: MeetingDigestFailure, to record: MeetingRecord) {
        let reason = MeetingDigestFailureReason(failure: failure)
        record.digestFailureReason = reason
        record.digestStatus = .failed
        voiceLog.error("meeting: digest failed reason=\(reason.rawValue, privacy: .public)")
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
            source: source,
            speaker: persisted.speaker)
    }

    /// BAK-335: verbal-handoff speaker attribution, run ONLY over the
    /// meeting channel, in time order — the you channel is Leon by
    /// construction and is never auto-stamped (the review UI renders "You"
    /// straight from the channel). Returns a map from each meeting-channel
    /// segment's persistent id to its attributed speaker; an id with no
    /// entry is unattributed, never a guess.
    /// Review FINDING 3 (effectiveness gap): real meeting-channel segments
    /// are near-word-level (~15 chars), so a handoff phrase routinely spans
    /// 2-3 raw segments ("pass it" / "back to" / "Alex." never contains the
    /// full "pass it back to Alex" phrase on its own). Attribution over raw
    /// per-segment text would silently match nothing on live data, so this
    /// merges into utterances FIRST — `MeetingUtteranceMerge`'s existing
    /// same-source, 1.5s-pause rule; every segment's `speaker` is nil at
    /// this point, so its speaker-boundary break is a no-op here — then
    /// attributes over the merged utterance TEXT, then stamps every
    /// CONSTITUENT segment of an attributed utterance, not just its first.
    private static func attributedSpeakers(
        for segments: [VoiceTranscriptSegment], context: ModelContext
    ) -> [String: String] {
        let meetingSegments = segments.filter { $0.source == .meeting }
        guard !meetingSegments.isEmpty else { return [:] }
        let utterances = MeetingUtteranceMerge.utterances(from: meetingSegments)
        let candidates = MeetingSpeakerCandidateSource.fetch(
            context: context, userTerms: VoiceLexiconUserTerms.load())
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: utterances.map(\.text), candidates: candidates)

        var result: [String: String] = [:]
        for (utterance, speaker) in zip(utterances, speakers) {
            guard let speaker else { continue }
            for segment in utterance.segments {
                result[MeetingTranscriptMerge.persistentID(for: segment)] = speaker
            }
        }
        return result
    }

    /// BAK-332: compare what the transcript proves happened against which
    /// audio channels actually finalized to disk. `status`/`audioFinalized`
    /// are never touched here — `.partial` renders as "Interrupted" in the
    /// review UI and would also hide the Generate/Retry digest buttons
    /// (both gate on `status == .ready`), which is wrong for a meeting whose
    /// recording and transcript are otherwise completely intact. A mismatch
    /// only sets `errorMessage`, which the review UI already surfaces
    /// unconditionally in the header.
    private func applySourceParity(segments: [VoiceTranscriptSegment], to record: MeetingRecord) {
        let transcribedChannels = Set(segments.map { segment -> MeetingSegmentSource in
            segment.source == .meeting ? .meeting : .you
        })
        var finalizedChannels: Set<MeetingSegmentSource> = []
        if record.youAudioPath != nil { finalizedChannels.insert(.you) }
        if record.meetingAudioPath != nil { finalizedChannels.insert(.meeting) }
        let startedSources = record.captureSources.compactMap(MeetingAudioSource.init(rawValue:))

        let verdict = MeetingSourceParity.evaluate(
            startedSources: startedSources,
            transcribedChannels: transcribedChannels,
            finalizedChannels: finalizedChannels)
        guard let message = verdict.userMessage else { return }
        record.errorMessage = message
        voiceLog.error(
            "meeting: source parity mismatch missing=\(verdict.missing.map(\.rawValue).joined(separator: ","), privacy: .public)")
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

    /// BAK-333: reclaim a finalized meeting's crash-recovery working files —
    /// a real 23-minute `ready` meeting was carrying ~285 MB across both
    /// `.partial.caf` sources plus a leftover manifest, ~7x the audio it
    /// actually kept. `MeetingWorkingFileCleanup` makes the decision (which
    /// files are safe to delete); this only executes it through the
    /// validated `MeetingAudioStore` URLs. Deletion is strictly
    /// best-effort — a failure logs and never touches the record, and only
    /// files that are actually present are removed (deleting an
    /// already-gone file is success, not failure, matching
    /// `MeetingAudioStore.deleteAudio`'s idempotence).
    ///
    /// Called from two places: right after a clean finalize
    /// (`stampAudioPaths`/`audioFinalized = true` above), and from
    /// `recoverOnLaunch` as a one-off sweep for meetings that finalized
    /// before this cleanup existed.
    private func cleanUpWorkingFiles(for record: MeetingRecord) {
        let startedSources = Set(
            record.captureSources
                .compactMap(MeetingAudioSource.init(rawValue:))
                .map(\.trackChannel))
        func finalExists(_ file: MeetingAudioFile) -> Bool {
            guard let url = try? store.fileURL(for: file, meetingUID: record.uid) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        var finalsThatExist: Set<MeetingSegmentSource> = []
        if finalExists(.you) { finalsThatExist.insert(.you) }
        if finalExists(.meeting) { finalsThatExist.insert(.meeting) }
        let manifestURL = try? store.fileURL(for: .recoveryManifest, meetingUID: record.uid)
        let hasManifest = manifestURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: startedSources,
            finalsThatExist: finalsThatExist,
            hasManifest: hasManifest)
        for file in toDelete {
            guard let url = try? store.fileURL(for: file, meetingUID: record.uid),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                voiceLog.error(
                    "meeting: working-file cleanup failed uid=\(record.uid, privacy: .public) file=\(file.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
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
