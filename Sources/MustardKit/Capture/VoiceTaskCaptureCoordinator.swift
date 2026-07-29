#if os(macOS)
import AppKit
import SwiftUI
import SwiftData
import Observation

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
    /// Reflect a merged draft in the UI.
    func apply(_ merged: VoiceTaskDraft)
    /// Dismiss the card (a newer capture replaces it).
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
        case committed(String)   // flashed briefly: "Added — <title>"
        case cancelled           // too short / nothing heard
        case denied              // mic or speech permission missing
        case unavailable(String) // recognizer/engine failure
    }

    // MARK: - Seams

    /// The speech engine seam. Live wiring adapts the F25 `SpeechTranscribing`
    /// engine until Task 5 swaps in `AppleSpeechSession`; tests inject stubs.
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

        /// Bridges the F25 SFSpeech engine into segment shape: partials become
        /// one rolling provisional segment, stop() one final segment. Deleted
        /// with the legacy engine in Task 5.
        @MainActor
        public static func legacy(_ transcriber: any SpeechTranscribing) -> Speech {
            Speech(
                authorize: { await transcriber.requestAuthorization() },
                begin: {
                    AsyncThrowingStream { continuation in
                        transcriber.onPartial = { text in
                            continuation.yield(VoiceTranscriptSegment(
                                id: "live", text: text, startSeconds: 0, endSeconds: 0,
                                isFinal: false, confidence: nil, source: .microphone))
                        }
                        do { try transcriber.start() } catch { continuation.finish(throwing: error) }
                    }
                },
                end: {
                    let text = await transcriber.stop()
                    guard !text.isEmpty else { return [] }
                    return [VoiceTranscriptSegment(
                        id: "final", text: text, startSeconds: 0, endSeconds: 0,
                        isFinal: true, confidence: nil, source: .microphone)]
                },
                cancel: { transcriber.cancel() })
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
    private let now: () -> Date

    private var pressedAt: Date?
    private var authorized = false
    private var segmentsByID: [String: VoiceTranscriptSegment] = [:]
    private var consumeTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var activeEditor: (any VoiceTaskQuickEditing)?

    public init(
        context: ModelContext,
        speech: Speech,
        hotKey: HotKeySeam,
        pill: PillPresentation,
        draft: @escaping (String, [String], Date) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure>,
        allowedAreas: @escaping () -> [String],
        presentEditor: @escaping @MainActor (MustardTask) -> (any VoiceTaskQuickEditing)?,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.speech = speech
        self.hotKey = hotKey
        self.pill = pill
        self.draftGenerator = draft
        self.allowedAreas = allowedAreas
        self.presentEditor = presentEditor
        self.now = now
    }

    /// F25-equivalent wiring: legacy SFSpeech engine, the real Carbon hotkey,
    /// the floating pill, no quick editor, and no on-device drafting (the
    /// legacy cleanup queue keeps that job until Task 5 rewires the app).
    public convenience init(context: ModelContext) {
        self.init(
            context: context,
            speech: .legacy(SpeechTranscriber()),
            hotKey: .live(PushToTalkHotKey()),
            pill: .panel(),
            draft: { _, _, _ in .failure(.model(.unavailable("On-device drafting is wired in Capture Task 5"))) },
            allowedAreas: { MeetingTaskSync.defaultAreaMap.values.sorted() },
            presentEditor: { _ in nil })
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
        guard phase != .recording else { return }   // key auto-repeat / re-entry
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
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.speech.begin()
                for try await segment in stream {
                    self.record(segment)
                }
            } catch {
                // Engine failure while (or before) recording — never mid-capture
                // silence: the pill explains, and any stable text is kept for
                // the release path.
                guard self.phase == .recording else { return }
                self.phase = .unavailable(error.localizedDescription)
                self.scheduleDismiss(after: 2.5)
            }
        }
    }

    func endCapture() {
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
            let finals: [VoiceTranscriptSegment]
            do {
                finals = try await self.speech.end()
            } catch {
                // Finalization failed: preserve the best stable transcript the
                // stream already delivered (spec §Error handling).
                finals = self.segmentsByID.values.filter(\.isFinal)
            }
            let transcript = VoiceCapture.transcript(from: finals)
            switch VoiceCapture.outcome(
                pressedAt: pressedAt, releasedAt: releasedAt, transcript: transcript
            ) {
            case .commit(let title):
                let task = self.insertCapture(title: title, transcript: transcript)
                self.activeEditor?.close()   // one visible card: newest capture wins
                let editor = self.presentEditor(task)
                self.activeEditor = editor
                self.phase = .committed(title)
                self.scheduleDismiss(after: 1.6)
                self.requestDrafting(for: task, transcript: transcript, editor: editor)
            case .cancelled:
                self.phase = .cancelled
                self.scheduleDismiss(after: 0.8)
            }
        }
    }

    // MARK: - Drafting

    /// Snapshot the editor's revision counters, ask the on-device generator for
    /// structure, and merge only fields the user hasn't touched since — on the
    /// main actor. A failed draft changes nothing: the task stays `.raw` and
    /// retryable from the card/task detail.
    private func requestDrafting(
        for task: MustardTask, transcript: String, editor: (any VoiceTaskQuickEditing)?
    ) {
        let requestRevisions = editor?.revisions ?? VoiceTaskFieldRevisions()
        let requestedAt = now()
        draftingTask = Task { [weak self] in
            guard let self else { return }
            guard case .success(let generated) = await self.draftGenerator(
                transcript, self.allowedAreas(), requestedAt
            ) else { return }
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
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.pill.hide()
            self?.phase = .idle
        }
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
