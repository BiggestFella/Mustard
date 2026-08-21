#if os(macOS)
import AppKit
import SwiftUI
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
/// `TextInserter`.
///
/// Dictation still holds no `ModelContext` of its own — the words go into
/// other apps. But since private local clip history exists, a completed
/// dictation ALSO lands there, by explicit spec decision
/// (`docs/superpowers/specs/2026-08-12-notch-shelf-redesign-design.md` §1 and
/// §3 "Dictation persistence"), which reverses this file's original
/// "never into Mustard's store" rule. History is reached only through the
/// injected `onFinalTranscript` hook (the coordinator stays store-free and
/// testable), it is offered once per capture — the first insert attempt, never
/// a retry — and **secure-field dictations are never stored anywhere**: they
/// are refused at press, and the offer additionally sits behind the
/// `DictationWhitespace.insertion` nil-guard.
@MainActor
@Observable
public final class SystemDictationCoordinator {
    /// The dictation pill seam. `.panel()` is the real nonactivating panel;
    /// tests inject `.none()`.
    public struct PillPresentation {
        public var show: @MainActor (SystemDictationCoordinator) -> Void
        public var hide: @MainActor () -> Void

        public init(
            show: @escaping @MainActor (SystemDictationCoordinator) -> Void,
            hide: @escaping @MainActor () -> Void
        ) {
            self.show = show
            self.hide = hide
        }

        public static func none() -> PillPresentation {
            PillPresentation(show: { _ in }, hide: {})
        }

        /// The real floating pill: nonactivating (dictation must never steal
        /// focus from the field being dictated into), top-centre under the
        /// notch/menu bar — the capture pill's pattern.
        @MainActor
        public static func panel() -> PillPresentation {
            let holder = DictationPillHolder()
            return PillPresentation(
                show: { coordinator in holder.show(for: coordinator) },
                hide: { holder.hide() })
        }
    }

    public private(set) var phase: SystemDictationPhase = .idle
    public private(set) var liveTranscript = ""
    public private(set) var hotKeyRegistration: HotKeyRegistration?
    /// The finalized words whenever insertion could not happen — never lost.
    public private(set) var recoveredTranscript: String?
    /// Where the current (or most recent) hold spent its time. Read by tests;
    /// logged at the end of every hold so real-hardware behaviour can be
    /// measured without a rebuild. See `DictationLatency`.
    public private(set) var latency = DictationLatency()

    private(set) var activationTask: Task<Void, Never>?
    private(set) var finalizeTask: Task<Void, Never>?

    private let snapshotFocus: @MainActor () throws -> FocusedTextTarget
    private let speech: VoiceTaskCaptureCoordinator.Speech
    private let hotKey: VoiceTaskCaptureCoordinator.HotKeySeam
    private let insert: @MainActor (String, FocusedTextTarget) async -> TextInsertionOutcome
    /// Clip-history seam: offered the finalized words, as spoken, once per
    /// capture. Injected so the coordinator keeps no store of its own.
    private let onFinalTranscript: (@MainActor (String) -> Void)?
    private let pill: PillPresentation
    /// Hard ceiling on waiting for the recognizer's final answer.
    private let finalizeTimeout: TimeInterval
    private let now: () -> Date
    /// Diagnostics clock, deliberately separate from `now`.
    ///
    /// `now` drives a decision — whether a hold was long enough to commit — and
    /// tests pin it to exact scripted instants. Reading it to timestamp a
    /// measurement would advance those scripts and change the behaviour being
    /// measured. Measuring must never perturb what it measures, so the marks
    /// read this instead; tests that assert timings inject it.
    private let latencyNow: () -> Date

    private var authorized = false
    /// Hold generation: bumped on every new hold (and retry), captured by
    /// every spawned task — a stale finalize/consume/dismiss can never mutate
    /// a newer hold's state.
    private var holdEpoch = 0
    private var target: FocusedTextTarget?
    private var pressedAt: Date?
    private var segmentsByID: [String: VoiceTranscriptSegment] = [:]
    private var consumeTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var finalizeContinuation: CheckedContinuation<[VoiceTranscriptSegment]?, Never>?

    public init(
        snapshotFocus: @escaping @MainActor () throws -> FocusedTextTarget,
        speech: VoiceTaskCaptureCoordinator.Speech,
        hotKey: VoiceTaskCaptureCoordinator.HotKeySeam,
        insert: @escaping @MainActor (String, FocusedTextTarget) async -> TextInsertionOutcome,
        onFinalTranscript: (@MainActor (String) -> Void)? = nil,
        pill: PillPresentation,
        finalizeTimeout: TimeInterval = 4,
        now: @escaping () -> Date = { .now },
        latencyNow: @escaping () -> Date = { .now }
    ) {
        self.snapshotFocus = snapshotFocus
        self.speech = speech
        self.hotKey = hotKey
        self.insert = insert
        self.onFinalTranscript = onFinalTranscript
        self.pill = pill
        self.finalizeTimeout = finalizeTimeout
        self.now = now
        self.latencyNow = latencyNow
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

    /// Swap the dictation chord live (Settings → Hotkeys).
    @discardableResult
    public func rebindHotKey(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        let registration = hotKey.rebind(keyCode, modifiers)
        hotKeyRegistration = registration
        return registration
    }

    func beginDictation() {
        guard phase != .listening else { return }   // key auto-repeat / re-entry
        holdEpoch += 1
        dismissTask?.cancel()

        // The target is captured BEFORE any audio starts — the words go where
        // the cursor was when the hold began, or nowhere.
        let snapshot: FocusedTextTarget
        do {
            snapshot = try snapshotFocus()
        } catch FocusReadError.accessibilityPermissionMissing {
            // Logged with the bundle path: a TCC grant can read as enabled in
            // System Settings while applying to a different copy of the app.
            voiceLog.notice(
                "dictation: refused, accessibility not trusted for \(Bundle.main.bundlePath, privacy: .public)")
            return refuse(.denied("Allow Accessibility in System Settings → Privacy & Security so dictation can type for you."))
        } catch {
            voiceLog.notice("dictation: refused, no focused text field (\(String(describing: error), privacy: .public))")
            return refuse(.recoverable("No text field is focused — click where the words should go, then hold the dictation key."))
        }
        voiceLog.notice(
            "dictation: focus read ok secure=\(snapshot.isSecure, privacy: .public) authorized=\(self.authorized, privacy: .public)")
        guard !snapshot.isSecure else {
            return refuse(.denied("Dictation never types into password fields."))
        }
        guard authorized else {
            return refuse(.denied("Allow the microphone in System Settings → Privacy & Security."))
        }

        target = snapshot
        pressedAt = now()
        latency.markPressed(latencyNow())
        segmentsByID = [:]
        liveTranscript = ""
        recoveredTranscript = nil
        phase = .listening
        pill.show(self)
        let epoch = holdEpoch
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.speech.begin()
                // The recognizer is up and the microphone has been live since
                // partway through `begin` — audio from before this point is
                // buffered, not lost (`MicrophonePreRoll`). This mark is what
                // tells us how long that buffer had to cover.
                if self.holdEpoch == epoch { self.latency.markListening(self.latencyNow()) }
                for try await segment in stream {
                    guard self.holdEpoch == epoch else { return }
                    self.record(segment)
                }
            } catch {
                // Speech failed mid-hold: stop the feed (the mic must never
                // stay hot) and preserve whatever stable text already landed.
                guard self.holdEpoch == epoch, self.phase == .listening else { return }
                await self.speech.cancel()
                guard self.holdEpoch == epoch else { return }
                self.pressedAt = nil
                // A hold that died mid-flight is the one most worth timing —
                // a failed cold start shows up here, not on the happy path.
                self.logLatency()
                let stable = VoiceCapture.transcript(
                    from: self.segmentsByID.values.filter(\.isFinal))
                self.recover(
                    transcript: stable.isEmpty ? nil : stable,
                    reason: error.localizedDescription)
            }
        }
    }

    func endDictation() {
        guard phase == .listening, let pressedAt, let target else { return }
        // Stamp the release before awaiting finalization — recognizer latency
        // must not count toward the minimum hold.
        let releasedAt = now()
        latency.markReleased(latencyNow())
        self.pressedAt = nil
        let epoch = holdEpoch
        if releasedAt.timeIntervalSince(pressedAt) < VoiceCapture.minimumHold {
            finalizeTask = Task { [weak self] in
                await self?.speech.cancel()   // an accidental tap
                guard let self, self.holdEpoch == epoch else { return }
                self.consumeTask?.cancel()
                // Timed too: a tap that felt deliberate but fell under the
                // minimum is worth being able to see in the log.
                self.logLatency()
                self.pill.hide()
                self.phase = .idle
            }
            return
        }
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            let finals = await self.boundedFinals()
            guard self.holdEpoch == epoch else { return }
            let transcript = VoiceCapture.transcript(from: finals)
            voiceLog.notice("dictation: finals=\(finals.count, privacy: .public) chars=\(transcript.count, privacy: .public)")
            guard !transcript.isEmpty else {
                self.logLatency()
                return self.recover(transcript: nil, reason: "Nothing was heard — the field is untouched.")
            }
            self.phase = .inserting
            // Strict release-time revalidation: the fresh snapshot must equal
            // the press-time one (same field, same cursor, same surroundings)
            // or the words go to safe recovery, never the wrong place.
            let fresh = try? self.snapshotFocus()
            guard fresh == target else {
                // Which part moved matters: a re-rendering field (value differs)
                // is a very different problem from focus actually leaving.
                voiceLog.notice("""
                    dictation: revalidation failed \
                    freshRead=\(fresh != nil, privacy: .public) \
                    samePID=\(fresh?.applicationPID == target.applicationPID, privacy: .public) \
                    sameElement=\(fresh?.elementIdentifier == target.elementIdentifier, privacy: .public) \
                    sameSelection=\(fresh?.selectedRange == target.selectedRange, privacy: .public) \
                    samePreceding=\(fresh?.precedingCharacter == target.precedingCharacter, privacy: .public) \
                    sameFollowing=\(fresh?.followingCharacter == target.followingCharacter, privacy: .public)
                    """)
                return self.recover(
                    transcript: transcript,
                    reason: "The field or cursor moved during dictation — the words are kept for you.")
            }
            // Contextual whitespace is decided against the PRESS-time snapshot;
            // nil means insertion must not happen at all (secure).
            guard let text = DictationWhitespace.insertion(text: transcript, target: target) else {
                return self.recover(transcript: transcript, reason: "Dictation never types into password fields.")
            }
            // Past the secure gate, so these words may be remembered: offer them
            // to clip history exactly once, here on the first attempt (a retry
            // must not create a second entry) and BEFORE the insert, so a failed
            // insertion still leaves the transcript recoverable from history.
            // Pre-normalization on purpose — history keeps the words as spoken;
            // the leading/trailing space is target-specific.
            self.onFinalTranscript?(transcript)
            let outcome = await self.insert(text, target)
            voiceLog.notice("dictation: insert outcome=\(String(describing: outcome), privacy: .public)")
            guard self.holdEpoch == epoch else { return }
            switch outcome {
            case .insertedDirectly, .insertedByPaste:
                self.latency.markInserted(self.latencyNow())
                self.logLatency()
                self.phase = .inserted
                self.scheduleIdle(after: 1.2)
            case .recoverable(let reason):
                self.logLatency()
                self.recover(transcript: transcript, reason: reason)
            }
        }
    }

    /// The recoverable pill's "Try Current Field": re-attempt insertion of the
    /// preserved transcript into whatever is focused NOW — a fresh snapshot,
    /// fresh whitespace, the same fail-closed rules. The transcript survives
    /// another failure, so retries can keep coming. Deliberately does NOT offer
    /// the transcript to clip history: the first attempt already did, and these
    /// are the same words.
    public func retryIntoCurrentField() {
        guard case .recoverable = phase, let transcript = recoveredTranscript else { return }
        holdEpoch += 1
        let epoch = holdEpoch
        dismissTask?.cancel()
        phase = .inserting
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            let fresh: FocusedTextTarget
            do {
                fresh = try self.snapshotFocus()
            } catch {
                return self.recover(transcript: transcript, reason: "No text field is focused — click where the words should go, then retry.")
            }
            guard let text = DictationWhitespace.insertion(text: transcript, target: fresh) else {
                return self.recover(transcript: transcript, reason: "Dictation never types into password fields.")
            }
            let outcome = await self.insert(text, fresh)
            guard self.holdEpoch == epoch else { return }
            switch outcome {
            case .insertedDirectly, .insertedByPaste:
                self.recoveredTranscript = nil
                self.phase = .inserted
                self.scheduleIdle(after: 1.2)
            case .recoverable(let reason):
                self.recover(transcript: transcript, reason: reason)
            }
        }
    }

    /// Wait for the recognizer, but never forever. A wedged analyzer — one
    /// whose result stream never finishes — would otherwise suspend
    /// `speech.end()` indefinitely, freezing the pill mid-dictation with a
    /// live microphone. Capture hit exactly this; dictation shares the
    /// machinery, so it gets the same ceiling.
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
            await speech.cancel()   // release the microphone
            consumeTask?.cancel()
            return stable
        }
        return raced
    }

    private func resumeFinalize(_ value: [VoiceTranscriptSegment]?) {
        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        continuation.resume(returning: value)
    }

    /// The pill's escape hatch: abandon whatever is in flight, release the
    /// microphone, insert nothing. Whatever goes wrong, there is a way out.
    public func dismiss() {
        guard phase != .idle else { return }
        holdEpoch += 1
        finalizeTask = Task { [weak self] in
            await self?.speech.cancel()
            guard let self else { return }
            self.resumeFinalize(nil)
            self.consumeTask?.cancel()
            self.dismissTask?.cancel()
            self.pressedAt = nil
            self.segmentsByID = [:]
            self.liveTranscript = ""
            self.recoveredTranscript = nil
            self.pill.hide()
            self.phase = .idle
        }
    }

    // MARK: - Internals

    private func refuse(_ refusal: SystemDictationPhase) {
        phase = refusal
        pill.show(self)
        scheduleIdle(after: 2.5)
    }

    /// Emits the hold's timings once, however the hold ended — inserted,
    /// recovered, failed mid-flight, or released under the minimum. Two
    /// numbers matter: `startup` (key-down → recognizer live, the window the
    /// pre-roll buffer has to cover) and `finish` (key-up → words in the
    /// field). Holds refused before the press was accepted have no marks and
    /// log nothing. Never logs transcript content — only durations.
    private func logLatency() {
        guard let summary = latency.summary else { return }
        voiceLog.notice("dictation: latency \(summary, privacy: .public)")
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
        let epoch = holdEpoch
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.holdEpoch == epoch else { return }
            self.pill.hide()
            self.phase = .idle
        }
    }
}

// MARK: - Live wiring (Dictation Task 5)

extension SystemDictationCoordinator {
    /// Production dictation: the live Accessibility reader + inserter, a
    /// fresh SpeechAnalyzer session per hold (macOS 27's live driver — on a
    /// macOS 26 install the pill reports dictation unavailable instead of
    /// failing silently), and the ⌃⌥D chord.
    ///
    /// `clipStore` is the clip-history sink: pass the app's store so completed
    /// dictations are also remembered locally (spec §1/§3). Held weakly — the
    /// coordinator lives as long as the app, and must not be what keeps a store
    /// alive. Omitting it (tests, previews) simply stores nothing.
    public static func live(clipStore: ClipStore? = nil) -> SystemDictationCoordinator {
        let reader = AccessibilityFocusReader.live()
        let inserter = TextInserter.live(reader: reader)
        return SystemDictationCoordinator(
            snapshotFocus: { try reader.snapshot() },
            speech: .liveMicrophone {
                guard #available(macOS 27.0, iOS 27.0, *) else {
                    throw VoiceSessionError.notReady(
                        .unavailable("Dictation needs macOS 27"))
                }
                return AppleSpeechSession.live()
            },
            hotKey: .live(PushToTalkHotKey.dictation()),
            insert: { text, target in await inserter.insert(text, into: target) },
            onFinalTranscript: { [weak clipStore] transcript in
                clipStore?.addDictation(transcript: transcript)
            },
            pill: .panel())
    }
}

/// Owns the one floating `NSPanel` for the dictation pill.
@MainActor
private final class DictationPillHolder {
    private var panel: NSPanel?

    func show(for coordinator: SystemDictationCoordinator) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
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
            panel.contentView = NSHostingView(rootView: SystemDictationPillView(coordinator: coordinator))
            self.panel = panel
        }
        if let screen = NotchScreenPicker.currentScreen(), let panel {
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
