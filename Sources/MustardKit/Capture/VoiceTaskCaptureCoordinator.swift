#if os(macOS)
import AppKit
import SwiftUI
import SwiftData
import Observation
import AVFoundation
import MustardShims
import os

/// Voice-capture diagnostics. `.notice` so it persists without enabling
/// debug logging: stream it with
/// `log stream --predicate 'subsystem == "com.cavehole.mustard"'`.
/// The live speech path can only be observed on real hardware, so a capture
/// leaves a trail rather than requiring a rebuild to investigate.
let voiceLog = Logger(subsystem: "com.cavehole.mustard", category: "voice")

/// What the coordinator needs from the quick-edit card (Capture Task 4
/// implements the real panel; tests inject a stub). The editor owns per-field
/// revision counters — the coordinator snapshots them when a drafting request
/// starts so a late model result can never overwrite a user edit.
@MainActor
public protocol VoiceTaskQuickEditing: AnyObject {
    /// The fields as currently shown (including any user edits).
    var draft: VoiceTaskDraft { get }
    /// Monotonic per-field edit counters, bumped by user edits only.
    var revisions: VoiceTaskFieldRevisions { get }
    /// True once the card was dismissed. Edits made after that (drawer,
    /// inbox) are not revision-tracked, so a closed card ENDS the drafting
    /// window — a late model result must not land anywhere.
    var isClosed: Bool { get }
    /// The card's retry affordance when a draft fails (spec: cleanup is
    /// retryable from the card); the coordinator installs it.
    var retryDraft: (() -> Void)? { get set }
    /// Reflect a merged draft in the UI.
    func apply(_ merged: VoiceTaskDraft)
    /// Save the current values to the task and dismiss (a newer capture
    /// COMMITS the previous card — its edits are never discarded).
    func commit()
    /// Dismiss without applying pending edits.
    func close()
}

/// Orchestrates modern push-to-talk capture (Capture Task 3, BAK-283 —
/// successor of the F25 `VoiceCaptureController`): global hotkey press →
/// segment stream drives the live pill → release → `VoiceCapture.outcome`
/// decides → commit inserts a raw Inbox task (verbatim transcript retained) →
/// the quick editor opens → on-device drafting proposes structure → merge
/// lands only on fields the user hasn't touched since the request began.
/// All decisions live in pure logic (`VoiceCapture`, `VoiceTaskDrafting`);
/// this class only sequences injected seams.
@MainActor
@Observable
public final class VoiceTaskCaptureCoordinator {
    public enum Phase: Equatable {
        case idle
        case recording
        /// Between release and the recognizer's final answer. Distinct from
        /// `.recording` so a slow finalize reads as progress, not a freeze.
        case finalizing
        case committed(String)   // flashed briefly: "Added — <title>"
        case cancelled           // too short / nothing heard
        case denied              // mic or speech permission missing
        case unavailable(String) // recognizer/engine failure
    }

    // MARK: - Seams

    /// The speech engine seam. Live wiring is `liveMicrophone` (a fresh
    /// `AppleSpeechSession` per capture, fed by the mic); tests inject stubs.
    public struct Speech {
        public var authorize: @MainActor () async -> Bool
        public var begin: @MainActor () async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error>
        public var end: @MainActor () async throws -> [VoiceTranscriptSegment]
        public var cancel: @MainActor () async -> Void

        public init(
            authorize: @escaping @MainActor () async -> Bool,
            begin: @escaping @MainActor () async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error>,
            end: @escaping @MainActor () async throws -> [VoiceTranscriptSegment],
            cancel: @escaping @MainActor () async -> Void
        ) {
            self.authorize = authorize
            self.begin = begin
            self.end = end
            self.cancel = cancel
        }

        /// The production bundle: a fresh transcription session per capture
        /// (`AppleSpeechSession` is one-shot by design), fed by the built-in
        /// microphone. Only the mic TCC grant is requested — SpeechAnalyzer
        /// transcription is on-device and needs no speech-recognition grant.
        ///
        /// - Parameter lexicon: contextual-vocabulary terms (BAK-334)
        ///   recomputed fresh for EACH capture (called once per `begin()`,
        ///   never per buffer) so a capture always sees the latest areas/
        ///   task lists/titles. Default `{ [] }` keeps existing callers of
        ///   this factory unchanged.
        @MainActor
        public static func liveMicrophone(
            makeSession: @escaping @MainActor () throws -> any VoiceTranscribing,
            lexicon: @escaping @MainActor () -> [String] = { [] }
        ) -> Speech {
            let feed = MicrophoneFeed(makeSession: makeSession, lexicon: lexicon)
            return Speech(
                authorize: { await AVCaptureDevice.requestAccess(for: .audio) },
                begin: { try await feed.begin() },
                end: { try await feed.end() },
                cancel: { await feed.cancel() })
        }
    }

    /// The hotkey seam: registration result + press/release binding.
    public struct HotKeySeam {
        public var register: @MainActor () -> HotKeyRegistration
        public var bind: @MainActor (_ onPress: @escaping () -> Void, _ onRelease: @escaping () -> Void) -> Void

        public init(
            register: @escaping @MainActor () -> HotKeyRegistration,
            bind: @escaping @MainActor (_ onPress: @escaping () -> Void, _ onRelease: @escaping () -> Void) -> Void
        ) {
            self.register = register
            self.bind = bind
        }

        @MainActor
        public static func live(_ hotKey: PushToTalkHotKey) -> HotKeySeam {
            HotKeySeam(
                register: { hotKey.register() },
                bind: { onPress, onRelease in
                    hotKey.onPress = onPress
                    hotKey.onRelease = onRelease
                })
        }
    }

    /// The pill panel seam so tests never build an `NSPanel`.
    public struct PillPresentation {
        public var show: @MainActor (VoiceTaskCaptureCoordinator) -> Void
        public var hide: @MainActor () -> Void

        public init(
            show: @escaping @MainActor (VoiceTaskCaptureCoordinator) -> Void,
            hide: @escaping @MainActor () -> Void
        ) {
            self.show = show
            self.hide = hide
        }

        public static func none() -> PillPresentation {
            PillPresentation(show: { _ in }, hide: {})
        }

        /// The real floating pill (HoverPanel pattern: non-activating, never
        /// steals focus), top-centre under the notch/menu bar.
        @MainActor
        public static func panel() -> PillPresentation {
            let holder = PanelHolder()
            return PillPresentation(
                show: { coordinator in holder.show(for: coordinator) },
                hide: { holder.hide() })
        }
    }

    // MARK: - State

    public private(set) var phase: Phase = .idle
    public private(set) var liveTranscript = ""
    public private(set) var hotKeyRegistration: HotKeyRegistration?

    /// In-flight work, exposed so tests (and Task 5 wiring) can await
    /// deterministic completion instead of sleeping.
    private(set) var activationTask: Task<Void, Never>?
    private(set) var finalizeTask: Task<Void, Never>?
    private(set) var draftingTask: Task<Void, Never>?

    private let context: ModelContext
    private let speech: Speech
    private let hotKey: HotKeySeam
    private let pill: PillPresentation
    private let draftGenerator: (String, [String], Date) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure>
    private let allowedAreas: () -> [String]
    private let presentEditor: @MainActor (MustardTask) -> (any VoiceTaskQuickEditing)?
    /// Hard ceiling on waiting for the recognizer's final answer.
    private let finalizeTimeout: TimeInterval
    private let now: () -> Date

    private var pressedAt: Date?
    private var authorized = false
    private var segmentsByID: [String: VoiceTranscriptSegment] = [:]
    private var consumeTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var activeEditor: (any VoiceTaskQuickEditing)?
    private var finalizeContinuation: CheckedContinuation<[VoiceTranscriptSegment]?, Never>?

    public init(
        context: ModelContext,
        speech: Speech,
        hotKey: HotKeySeam,
        pill: PillPresentation,
        draft: @escaping (String, [String], Date) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure>,
        allowedAreas: @escaping () -> [String],
        presentEditor: @escaping @MainActor (MustardTask) -> (any VoiceTaskQuickEditing)?,
        finalizeTimeout: TimeInterval = 4,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.speech = speech
        self.hotKey = hotKey
        self.pill = pill
        self.draftGenerator = draft
        self.allowedAreas = allowedAreas
        self.presentEditor = presentEditor
        self.finalizeTimeout = finalizeTimeout
        self.now = now
    }

    /// Production wiring (Capture Task 5): SpeechAnalyzer transcription (a
    /// fresh `AppleSpeechSession` per capture — macOS 27's live driver; on a
    /// macOS 26 floor install the capture path reports itself unavailable
    /// instead of failing silently), Apple Intelligence drafting, the Carbon
    /// hotkey, the floating pill, and the notch-adjacent quick editor.
    public convenience init(context: ModelContext, navigation: NotchNavigation? = nil) {
        let editor = VoiceTaskQuickEditController(context: context, navigation: navigation)
        let generator = VoiceTaskDraftGenerator(
            service: OnDeviceLanguageService.live(),
            calendar: .current,
            loadPrompt: VoiceTaskDraftGenerator.bundledPrompt)
        self.init(
            context: context,
            speech: .liveMicrophone(
                makeSession: {
                    guard #available(macOS 27.0, *) else {
                        throw VoiceSessionError.notReady(
                            .unavailable("Voice capture needs macOS 27"))
                    }
                    return AppleSpeechSession.live()
                },
                lexicon: {
                    VoiceLexiconSource.fetch(
                        context: context, now: .now, userTerms: VoiceLexiconUserTerms.load())
                }),
            hotKey: .live(PushToTalkHotKey()),
            pill: .panel(),
            draft: { transcript, areas, now in
                await generator.draft(transcript: transcript, allowedAreas: areas, now: now)
            },
            allowedAreas: {
                // Every area the user actually has, plus the known client map —
                // both are "areas the model may pick", never invent.
                let existing = ((try? context.fetch(FetchDescriptor<Area>())) ?? []).map(\.name)
                return Set(existing).union(MeetingTaskSync.defaultAreaMap.values).sorted()
            },
            presentEditor: { task in editor.present(for: task) })
    }

    // MARK: - Lifecycle

    /// Claim the hotkey (surfacing a conflict — never silently) and pre-flight
    /// permissions so the TCC prompts appear at launch, not mid-capture with
    /// the key held down.
    public func activate() {
        hotKey.bind({ [weak self] in self?.beginCapture() },
                    { [weak self] in self?.endCapture() })
        hotKeyRegistration = hotKey.register()
        activationTask = Task { [weak self] in
            guard let self else { return }
            self.authorized = await self.speech.authorize()
        }
    }

    func beginCapture() {
        voiceLog.notice("beginCapture entered phase=\(String(describing: self.phase), privacy: .public)")
        // Auto-repeat, and re-press while the previous capture is still
        // finalizing (bounded below, so the window is short and self-clearing).
        guard phase != .recording, phase != .finalizing else { return }
        dismissTask?.cancel()
        pressedAt = now()
        segmentsByID = [:]
        liveTranscript = ""
        guard authorized else {
            phase = .denied
            pill.show(self)
            scheduleDismiss(after: 2.5)
            return
        }
        phase = .recording
        pill.show(self)
        voiceLog.notice("capture: begin")
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.speech.begin()
                for try await segment in stream {
                    self.record(segment)
                }
            } catch {
                // Engine failure mid-recording. Never leave the mic feed hot,
                // and never discard stable text: whatever already finalized
                // commits as a task (spec §Error handling); only a capture
                // with nothing stable surfaces as unavailable.
                guard self.phase == .recording else { return }
                await self.speech.cancel()
                self.pressedAt = nil
                let stable = VoiceCapture.transcript(
                    from: self.segmentsByID.values.filter(\.isFinal))
                if stable.isEmpty {
                    self.phase = .unavailable(error.localizedDescription)
                    self.scheduleDismiss(after: 2.5)
                } else {
                    self.finalizeTask = Task { [weak self] in
                        self?.commitCapture(transcript: stable)
                    }
                }
            }
        }
    }

    func endCapture() {
        voiceLog.notice(
            "endCapture entered phase=\(String(describing: self.phase), privacy: .public) hasPressedAt=\(self.pressedAt != nil, privacy: .public)")
        guard phase == .recording, let pressedAt else { return }
        // Stamp the release BEFORE awaiting the recognizer — its finalization
        // latency must not count toward the minimum-hold gate.
        let releasedAt = now()
        self.pressedAt = nil
        if releasedAt.timeIntervalSince(pressedAt) < VoiceCapture.minimumHold {
            finalizeTask = Task { [weak self] in
                await self?.speech.cancel()   // an accidental tap: no transcript wanted
                self?.consumeTask?.cancel()
                self?.phase = .cancelled
                self?.scheduleDismiss(after: 0.8)
            }
            return
        }
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            self.phase = .finalizing
            voiceLog.notice("capture: finalizing (streamed \(self.segmentsByID.count, privacy: .public) segments)")
            let finals = await self.boundedFinals()
            let transcript = VoiceCapture.transcript(from: finals)
            voiceLog.notice(
                "capture: finals=\(finals.count, privacy: .public) transcriptChars=\(transcript.count, privacy: .public)")
            switch VoiceCapture.outcome(
                pressedAt: pressedAt, releasedAt: releasedAt, transcript: transcript
            ) {
            case .commit:
                self.commitCapture(transcript: transcript)
            case .cancelled:
                self.phase = .cancelled
                self.scheduleDismiss(after: 0.8)
            }
        }
    }

    /// Wait for the recognizer's final answer, but never forever. A wedged
    /// analyzer — one whose result stream never finishes, which happens when
    /// the session never truly started — used to leave `speech.end()`
    /// suspended indefinitely: the phase stayed `.recording`, the pill sat on
    /// "Listening…", and the microphone stayed live with no way out. After
    /// `finalizeTimeout` we fall back to the stable segments already streamed
    /// and tear the feed down.
    private func boundedFinals() async -> [VoiceTranscriptSegment] {
        let stable = Array(segmentsByID.values.filter(\.isFinal))
        let raced: [VoiceTranscriptSegment]? = await withCheckedContinuation { continuation in
            finalizeContinuation = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                let finals = try? await self.speech.end()
                self.resumeFinalize(finals ?? stable)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.finalizeTimeout ?? 4))
                self?.resumeFinalize(nil)
            }
        }
        guard let raced else {
            // Timed out: release the microphone rather than leaving it hot.
            // (The suspended end() unblocks once the driver is cancelled.)
            await speech.cancel()
            consumeTask?.cancel()
            return stable
        }
        return raced
    }

    /// Resume the finalize race exactly once, whichever arm gets there first.
    private func resumeFinalize(_ value: [VoiceTranscriptSegment]?) {
        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        continuation.resume(returning: value)
    }

    /// The pill's escape hatch: throw away whatever is in flight, release the
    /// microphone, and dismiss. Nothing is saved — a capture the user chose to
    /// abandon should leave no trace.
    public func abandon() {
        voiceLog.notice("abandon phase=\(String(describing: self.phase), privacy: .public)")
        guard phase != .idle else { return }
        finalizeTask = Task { [weak self] in
            await self?.speech.cancel()
            guard let self else { return }
            self.resumeFinalize(nil)
            self.consumeTask?.cancel()
            self.dismissTask?.cancel()
            self.pressedAt = nil
            self.segmentsByID = [:]
            self.liveTranscript = ""
            self.pill.hide()
            self.phase = .idle
        }
    }

    /// Land one finalized transcript: insert the raw task, COMMIT the previous
    /// card's current values (spec: a new capture never discards them), open
    /// the new card, and kick drafting.
    private func commitCapture(transcript: String) {
        // The spoken words are the task's CONTENT, not its name: a long
        // dictation makes an unreadable title. They go into the notes, and the
        // title is a readable stub until drafting proposes a real one.
        let title = VoiceCapture.fallbackTitle(from: transcript)
        guard !VoiceCapture.normalizeTitle(transcript).isEmpty else {
            phase = .cancelled
            scheduleDismiss(after: 0.8)
            return
        }
        let task = insertCapture(title: title, transcript: transcript)
        activeEditor?.commit()   // one visible card; its edits are saved, not lost
        let editor = presentEditor(task)
        activeEditor = editor
        phase = .committed(title)
        scheduleDismiss(after: 1.6)
        requestDrafting(for: task, transcript: transcript, editor: editor)
    }

    // MARK: - Drafting

    /// Snapshot the editor's revision counters, ask the on-device generator for
    /// structure, and merge only fields the user hasn't touched since — on the
    /// main actor. A failed draft changes nothing: the task stays `.raw` and
    /// retryable from the card/task detail.
    private func requestDrafting(
        for task: MustardTask, transcript: String, editor: (any VoiceTaskQuickEditing)?
    ) {
        editor?.retryDraft = nil
        let requestRevisions = editor?.revisions ?? VoiceTaskFieldRevisions()
        let requestedAt = now()
        draftingTask = Task { [weak self] in
            guard let self else { return }
            guard case .success(let generated) = await self.draftGenerator(
                transcript, self.allowedAreas(), requestedAt
            ) else {
                voiceLog.error("draft failed — task stays raw")
                // Retryable from the card (spec): the task stays .raw and the
                // card offers Draft Again while it is still open.
                editor?.retryDraft = { [weak self] in
                    self?.requestDrafting(for: task, transcript: transcript, editor: editor)
                }
                return
            }
            // A closed card ends the drafting window: edits made afterwards
            // (drawer, inbox) are not revision-tracked, so a late result must
            // not overwrite them.
            if let editor, editor.isClosed { return }
            let current = editor?.draft ?? VoiceTaskDraft(
                title: task.title,
                notes: task.notes.isEmpty ? nil : task.notes,
                areaName: task.list?.area?.name,
                scheduledDate: task.scheduledAt,
                urls: task.links.compactMap { URL(string: $0.url) })
            let merged = VoiceTaskDrafting.merge(
                generated: generated,
                into: current,
                revisions: editor?.revisions ?? VoiceTaskFieldRevisions(),
                requestRevisions: requestRevisions)
            voiceLog.notice("draft applied title=\(merged.title.count, privacy: .public) chars")
            self.apply(merged, to: task)
            editor?.apply(merged)
        }
    }

    // MARK: - Task mutation

    private func insertCapture(title: String, transcript: String) -> MustardTask {
        let task = MustardTask(title: title)
        task.source = "voice"
        task.sourceContext = "Voice capture"
        task.captureState = .raw
        task.captureTranscript = transcript
        // Visible and editable, unlike captureTranscript which is immutable
        // evidence. Drafting may refine it; the verbatim copy always survives.
        task.notes = transcript
        context.insert(task)
        try? context.save()
        return task
    }

    /// Land a merged draft on the task. The verbatim transcript is never
    /// touched; a successful draft marks the capture `.cleaned`.
    private func apply(_ merged: VoiceTaskDraft, to task: MustardTask) {
        task.title = merged.title
        if let notes = merged.notes { task.notes = notes }
        if let date = merged.scheduledDate {
            // Voice drafts are date-only by prompt contract → the 9:00
            // untimed quick-capture convention.
            task.scheduledAt = date
            task.isTimed = false
            PersonalBoard.normalizePlacement(task)
        }
        if let areaName = merged.areaName { task.stampArea(named: areaName, in: context) }
        if !merged.urls.isEmpty {
            task.links = merged.urls.map {
                TaskLink(label: $0.host ?? $0.absoluteString, url: $0.absoluteString)
            }
        }
        task.captureState = .cleaned
        task.captureNextAttemptAt = nil
        try? context.save()
    }

    // MARK: - Recording

    private func record(_ segment: VoiceTranscriptSegment) {
        segmentsByID[segment.id] = segment
        liveTranscript = VoiceCapture.liveTranscript(Array(segmentsByID.values))
        voiceLog.notice(
            "segment id=\(segment.id, privacy: .public) final=\(segment.isFinal, privacy: .public) chars=\(segment.text.count, privacy: .public) live=\(self.liveTranscript.count, privacy: .public)")
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            voiceLog.notice("dismiss -> idle")
            self?.pill.hide()
            self?.phase = .idle
        }
    }
}

// MARK: - Live microphone feed

/// Owns the AVAudioEngine mic tap for one capture at a time and pumps buffers
/// into a fresh transcription session. The tap runs on the audio thread and
/// reuses its buffer after each callback, so buffers are deep-copied and then
/// consumed by ONE serial task — analyzer input must keep arrival order.
@MainActor
private final class MicrophoneFeed {
    private let makeSession: @MainActor () throws -> any VoiceTranscribing
    /// Contextual-vocabulary provider (BAK-334), called fresh at the top of
    /// every `begin()` so a capture always biases on the current areas/
    /// task lists/titles rather than whatever was true at app launch.
    private let lexicon: @MainActor () -> [String]
    /// One engine per capture, created in `begin`. A long-lived engine caches
    /// the input device's format across sleep/wake and device swaps, and
    /// installing a tap with that stale format makes AVFAudio raise an
    /// NSException (observed 2026-08-11: hw 44.1kHz vs cached 48kHz after an
    /// overnight sleep — the exception poisoned Swift concurrency and crashed
    /// the app on the next button click).
    private var engine: AVAudioEngine?
    private var session: (any VoiceTranscribing)?
    private var pump: Task<Void, Never>?
    private var chunks: AsyncStream<AudioChunk>.Continuation?
    /// Bumped by every begin and every cancel. `begin` is async, so a cancel
    /// can land mid-setup; without this the teardown runs BEFORE the tap is
    /// installed and the microphone is left running with nothing owning it
    /// (observed: cancel at .978, tap installed at 1.041, buffers climbing).
    private var generation = 0

    init(
        makeSession: @escaping @MainActor () throws -> any VoiceTranscribing,
        lexicon: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.makeSession = makeSession
        self.lexicon = lexicon
    }

    func begin() async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error> {
        // Always start from a clean slate. A capture that ended abnormally
        // (wedged finalize, error path, abandon) can leave a live analyzer
        // session and an unfinished pump behind; overwriting them orphaned
        // both and left the analyzer holding resources, which made the NEXT
        // capture transcribe nothing.
        await cancel()
        generation += 1
        let mine = generation

        let session = try makeSession()
        // BAK-334: computed once for this capture, applied before the
        // session starts. A biasing failure never blocks capture.
        try? await session.setContext(lexicon())
        let stream = try await session.start(source: .microphone)
        // A cancel that arrived during that await already ran its teardown,
        // so finishing setup now would strand a live tap. Undo and bail.
        guard generation == mine else {
            await session.cancel()
            throw CancellationError()
        }
        self.session = session

        let (buffers, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        chunks = continuation
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A device mid-switch (Bluetooth connecting, input changing) reports a
        // degenerate or inconsistent format; installing a tap on it yields
        // silence at best and an NSException at worst. Fail loudly so the
        // pill says so instead of recording nothing.
        guard format.sampleRate > 0, format.channelCount > 0,
              format.sampleRate == input.inputFormat(forBus: 0).sampleRate else {
            await abandonFailedStart(session)
            throw VoiceSessionError.audioFormatUnavailable
        }
        // AVFAudio signals misconfiguration by raising ObjC exceptions, and
        // one escaping through this async frame poisons the concurrency
        // runtime (delayed SIGSEGV in MainActor.assumeIsolated). Catch and
        // convert to a thrown error the pill's recovery path already handles.
        var startError: Error?
        let raised = MSTDCatchException {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
                guard let copy = buffer.deepCopy() else { return }
                continuation.yield(AudioChunk(buffer: copy, time: when))
            }
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let raised {
            voiceLog.error(
                "feed: audio engine raised \(raised.name.rawValue, privacy: .public): \(raised.reason ?? "no reason", privacy: .public)")
            await abandonFailedStart(session)
            throw VoiceSessionError.audioEngineFailure(raised.reason ?? raised.name.rawValue)
        }
        if let startError {
            await abandonFailedStart(session)
            throw startError
        }
        voiceLog.notice(
            "feed: tap installed rate=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
        pump = Task {
            var appended = 0
            for await chunk in buffers {
                do {
                    try await session.append(chunk.buffer, at: chunk.time)
                    appended += 1
                    if appended == 1 || appended % 50 == 0 {
                        voiceLog.notice("feed: appended \(appended, privacy: .public) buffers")
                    }
                } catch {
                    voiceLog.error("feed: append failed \(error.localizedDescription, privacy: .public)")
                }
            }
            voiceLog.notice("feed: pump ended after \(appended, privacy: .public) buffers")
        }
        return stream
    }

    func end() async throws -> [VoiceTranscriptSegment] {
        stopAudio()
        chunks?.finish()
        chunks = nil
        await pump?.value   // drain queued audio before finalizing
        pump = nil
        guard let session else { return [] }
        self.session = nil
        return try await session.finish()
    }

    func cancel() async {
        generation += 1
        stopAudio()
        chunks?.finish()
        chunks = nil
        pump?.cancel()
        pump = nil
        if let session {
            self.session = nil
            await session.cancel()
        }
    }

    private func stopAudio() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Undo a partially-started capture: the mic must never stay hot and the
    /// analyzer session must not dangle behind a thrown `begin`.
    private func abandonFailedStart(_ session: any VoiceTranscribing) async {
        stopAudio()
        chunks?.finish()
        chunks = nil
        self.session = nil
        await session.cancel()
    }
}

/// One copied mic buffer crossing from the audio thread into async land.
private struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime?
}

private extension AVAudioPCMBuffer {
    /// The tap's buffer is reused once the callback returns; anything that
    /// outlives it needs its own copy.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

// MARK: - Pill panel holder (live presentation)

/// Owns the one floating `NSPanel` for the live pill.
@MainActor
private final class PanelHolder {
    private var panel: NSPanel?

    func show(for coordinator: VoiceTaskCaptureCoordinator) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.contentView = NSHostingView(rootView: VoiceCapturePillView(controller: coordinator))
            self.panel = panel
        }
        if let screen = NSScreen.main, let panel {
            // Top-centre, tucked under the notch/menu bar where the eye already is.
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - 8))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
#endif
