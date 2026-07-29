#if os(macOS)
import AppKit
import Observation

/// Where a system-wide dictation hold is, phase by phase (Dictation Task 4).
public enum SystemDictationPhase: Equatable, Sendable {
    case idle
    case listening
    case inserting
    case inserted
    /// Nothing was inserted; the transcript is preserved in
    /// `recoveredTranscript` for the pill's copy/retry affordances.
    case recoverable(String)
    /// A hard refusal: missing permission, or a secure field.
    case denied(String)
}

/// Coordinates hold-⌃⌥D-to-dictate anywhere (Dictation Task 4, BAK-290):
/// snapshot the focused field BEFORE any audio starts, stream provisional
/// text into the (nonactivating) pill, finalize on release, revalidate the
/// target, normalize whitespace via `DictationWhitespace`, and insert through
/// `TextInserter`. Deliberately holds no `ModelContext` — dictation writes
/// into other apps, never into Mustard's store.
@MainActor
@Observable
public final class SystemDictationCoordinator {
    /// The dictation pill seam (Task 5 builds the real panel).
    public struct PillPresentation {
        public var show: @MainActor () -> Void
        public var hide: @MainActor () -> Void

        public init(show: @escaping @MainActor () -> Void, hide: @escaping @MainActor () -> Void) {
            self.show = show
            self.hide = hide
        }

        public static func none() -> PillPresentation {
            PillPresentation(show: {}, hide: {})
        }
    }

    public private(set) var phase: SystemDictationPhase = .idle
    public private(set) var liveTranscript = ""
    public private(set) var hotKeyRegistration: HotKeyRegistration?
    /// The finalized words whenever insertion could not happen — never lost.
    public private(set) var recoveredTranscript: String?

    private(set) var activationTask: Task<Void, Never>?
    private(set) var finalizeTask: Task<Void, Never>?

    private let snapshotFocus: @MainActor () throws -> FocusedTextTarget
    private let speech: VoiceTaskCaptureCoordinator.Speech
    private let hotKey: VoiceTaskCaptureCoordinator.HotKeySeam
    private let insert: @MainActor (String, FocusedTextTarget) async -> TextInsertionOutcome
    private let pill: PillPresentation
    private let now: () -> Date

    private var authorized = false
    private var target: FocusedTextTarget?
    private var pressedAt: Date?
    private var segmentsByID: [String: VoiceTranscriptSegment] = [:]
    private var consumeTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    public init(
        snapshotFocus: @escaping @MainActor () throws -> FocusedTextTarget,
        speech: VoiceTaskCaptureCoordinator.Speech,
        hotKey: VoiceTaskCaptureCoordinator.HotKeySeam,
        insert: @escaping @MainActor (String, FocusedTextTarget) async -> TextInsertionOutcome,
        pill: PillPresentation,
        now: @escaping () -> Date = { .now }
    ) {
        self.snapshotFocus = snapshotFocus
        self.speech = speech
        self.hotKey = hotKey
        self.insert = insert
        self.pill = pill
        self.now = now
    }

    /// Claim the dictation chord (a conflict is surfaced, never silent) and
    /// pre-flight the microphone grant.
    public func activate() {
        hotKey.bind({ [weak self] in self?.beginDictation() },
                    { [weak self] in self?.endDictation() })
        hotKeyRegistration = hotKey.register()
        activationTask = Task { [weak self] in
            guard let self else { return }
            self.authorized = await self.speech.authorize()
        }
    }

    func beginDictation() {
        guard phase != .listening else { return }   // key auto-repeat / re-entry
        dismissTask?.cancel()

        // The target is captured BEFORE any audio starts — the words go where
        // the cursor was when the hold began, or nowhere.
        let snapshot: FocusedTextTarget
        do {
            snapshot = try snapshotFocus()
        } catch FocusReadError.accessibilityPermissionMissing {
            return refuse(.denied("Allow Accessibility in System Settings → Privacy & Security so dictation can type for you."))
        } catch {
            return refuse(.recoverable("No text field is focused — click where the words should go, then hold the dictation key."))
        }
        guard !snapshot.isSecure else {
            return refuse(.denied("Dictation never types into password fields."))
        }
        guard authorized else {
            return refuse(.denied("Allow the microphone in System Settings → Privacy & Security."))
        }

        target = snapshot
        pressedAt = now()
        segmentsByID = [:]
        liveTranscript = ""
        recoveredTranscript = nil
        phase = .listening
        pill.show()
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.speech.begin()
                for try await segment in stream {
                    self.record(segment)
                }
            } catch {
                guard self.phase == .listening else { return }
                self.phase = .recoverable(error.localizedDescription)
                self.scheduleIdle(after: 2.5)
            }
        }
    }

    func endDictation() {
        guard phase == .listening, let pressedAt, let target else { return }
        // Stamp the release before awaiting finalization — recognizer latency
        // must not count toward the minimum hold.
        let releasedAt = now()
        self.pressedAt = nil
        if releasedAt.timeIntervalSince(pressedAt) < VoiceCapture.minimumHold {
            finalizeTask = Task { [weak self] in
                await self?.speech.cancel()   // an accidental tap
                self?.consumeTask?.cancel()
                self?.pill.hide()
                self?.phase = .idle
            }
            return
        }
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            let finals: [VoiceTranscriptSegment]
            do {
                finals = try await self.speech.end()
            } catch {
                // Preserve whatever stable text already streamed.
                finals = self.segmentsByID.values.filter(\.isFinal)
            }
            let transcript = VoiceCapture.transcript(from: finals)
            guard !transcript.isEmpty else {
                return self.recover(transcript: nil, reason: "Nothing was heard — the field is untouched.")
            }
            self.phase = .inserting
            // Contextual whitespace is decided against the PRESS-time snapshot;
            // nil means insertion must not happen at all (secure).
            guard let text = DictationWhitespace.insertion(text: transcript, target: target) else {
                return self.recover(transcript: transcript, reason: "Dictation never types into password fields.")
            }
            switch await self.insert(text, target) {
            case .insertedDirectly, .insertedByPaste:
                self.phase = .inserted
                self.scheduleIdle(after: 1.2)
            case .recoverable(let reason):
                self.recover(transcript: transcript, reason: reason)
            }
        }
    }

    // MARK: - Internals

    private func refuse(_ refusal: SystemDictationPhase) {
        phase = refusal
        pill.show()
        scheduleIdle(after: 2.5)
    }

    private func recover(transcript: String?, reason: String) {
        recoveredTranscript = transcript
        phase = .recoverable(reason)
        // Linger long enough to read/copy; the transcript itself survives
        // until the next press regardless.
        scheduleIdle(after: 4)
    }

    private func record(_ segment: VoiceTranscriptSegment) {
        segmentsByID[segment.id] = segment
        liveTranscript = VoiceCapture.liveTranscript(Array(segmentsByID.values))
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.pill.hide()
            self?.phase = .idle
        }
    }
}
#endif
