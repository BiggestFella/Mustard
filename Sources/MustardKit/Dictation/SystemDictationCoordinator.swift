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
/// `TextInserter`. Deliberately holds no `ModelContext` — dictation writes
/// into other apps, never into Mustard's store.
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

    private(set) var activationTask: Task<Void, Never>?
    private(set) var finalizeTask: Task<Void, Never>?

    private let snapshotFocus: @MainActor () throws -> FocusedTextTarget
    private let speech: VoiceTaskCaptureCoordinator.Speech
    private let hotKey: VoiceTaskCaptureCoordinator.HotKeySeam
    private let insert: @MainActor (String, FocusedTextTarget) async -> TextInsertionOutcome
    private let pill: PillPresentation
    private let now: () -> Date

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
        holdEpoch += 1
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
        pill.show(self)
        let epoch = holdEpoch
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.speech.begin()
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
        self.pressedAt = nil
        let epoch = holdEpoch
        if releasedAt.timeIntervalSince(pressedAt) < VoiceCapture.minimumHold {
            finalizeTask = Task { [weak self] in
                await self?.speech.cancel()   // an accidental tap
                guard let self, self.holdEpoch == epoch else { return }
                self.consumeTask?.cancel()
                self.pill.hide()
                self.phase = .idle
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
            guard self.holdEpoch == epoch else { return }
            let transcript = VoiceCapture.transcript(from: finals)
            guard !transcript.isEmpty else {
                return self.recover(transcript: nil, reason: "Nothing was heard — the field is untouched.")
            }
            self.phase = .inserting
            // Strict release-time revalidation: the fresh snapshot must equal
            // the press-time one (same field, same cursor, same surroundings)
            // or the words go to safe recovery, never the wrong place.
            guard (try? self.snapshotFocus()) == target else {
                return self.recover(
                    transcript: transcript,
                    reason: "The field or cursor moved during dictation — the words are kept for you.")
            }
            // Contextual whitespace is decided against the PRESS-time snapshot;
            // nil means insertion must not happen at all (secure).
            guard let text = DictationWhitespace.insertion(text: transcript, target: target) else {
                return self.recover(transcript: transcript, reason: "Dictation never types into password fields.")
            }
            let outcome = await self.insert(text, target)
            guard self.holdEpoch == epoch else { return }
            switch outcome {
            case .insertedDirectly, .insertedByPaste:
                self.phase = .inserted
                self.scheduleIdle(after: 1.2)
            case .recoverable(let reason):
                self.recover(transcript: transcript, reason: reason)
            }
        }
    }

    /// The recoverable pill's "Try Current Field": re-attempt insertion of the
    /// preserved transcript into whatever is focused NOW — a fresh snapshot,
    /// fresh whitespace, the same fail-closed rules. The transcript survives
    /// another failure, so retries can keep coming.
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

    // MARK: - Internals

    private func refuse(_ refusal: SystemDictationPhase) {
        phase = refusal
        pill.show(self)
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
    public static func live() -> SystemDictationCoordinator {
        let reader = AccessibilityFocusReader.live()
        let inserter = TextInserter.live(reader: reader)
        return SystemDictationCoordinator(
            snapshotFocus: { try reader.snapshot() },
            speech: .liveMicrophone {
                guard #available(macOS 27.0, *) else {
                    throw VoiceSessionError.notReady(
                        .unavailable("Dictation needs macOS 27"))
                }
                return AppleSpeechSession.live()
            },
            hotKey: .live(PushToTalkHotKey.dictation()),
            insert: { text, target in await inserter.insert(text, into: target) },
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
        if let screen = NSScreen.main, let panel {
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
