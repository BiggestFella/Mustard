import XCTest
import SwiftData
@testable import MustardKit

/// System-wide dictation coordination (Dictation Task 4, BAK-290): snapshot
/// the focused field BEFORE speech starts, stream provisional text, finalize
/// on release, revalidate + whitespace-normalize + insert — and never touch
/// SwiftData directly (clip history is reached through an injected hook, and
/// never for secure fields). All seams stubbed; time injected.
@MainActor
final class SystemDictationCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSince1970: 1_784_714_400)

    private func target(secure: Bool = false) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 42,
            elementIdentifier: "42#token#AXTextField#Notes",
            selectedRange: NSRange(location: 5, length: 0),
            precedingCharacter: "o",
            followingCharacter: nil,
            isSecure: secure)
    }

    private func seg(_ id: String, _ text: String, final: Bool) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: 0, endSeconds: 1,
            isFinal: final, confidence: nil, source: .microphone)
    }

    private final class Clock {
        var times: [Date]
        private var index = 0
        init(_ times: [Date]) { self.times = times }
        func next() -> Date {
            defer { index = min(index + 1, times.count - 1) }
            return times[index]
        }
    }

    /// Records the order of every seam call so sequencing is assertable.
    @MainActor
    private final class Harness {
        var events: [String] = []
        var snapshotResult: Result<FocusedTextTarget, FocusReadError>
        var finals: [VoiceTranscriptSegment] = []
        var endThrows = false
        /// Reproduces a wedged analyzer: `end()` never returns.
        var endHangs = false
        var insertOutcome: TextInsertionOutcome = .insertedDirectly
        var insertedText: String?
        var continuation: AsyncThrowingStream<VoiceTranscriptSegment, Error>.Continuation?
        var speechCancelled = false
        /// Everything the coordinator offered to clip history, in order.
        var offeredTranscripts: [String] = []
        /// When set, insert() suspends on a continuation handed to this
        /// closure until the test resumes it.
        var insertGateWaiter: ((CheckedContinuation<Void, Never>) -> Void)?

        init(target: FocusedTextTarget) {
            snapshotResult = .success(target)
        }

        var reader: AccessibilityFocusReader {
            AccessibilityFocusReader(
                isTrusted: { true },
                probe: { nil })
        }

        func makeCoordinator(
            clock: Clock,
            registration: HotKeyRegistration = .registered
        ) -> SystemDictationCoordinator {
            SystemDictationCoordinator(
                snapshotFocus: {
                    self.events.append("snapshot")
                    return try self.snapshotResult.get()
                },
                speech: VoiceTaskCaptureCoordinator.Speech(
                    authorize: { true },
                    begin: {
                        self.events.append("speech.begin")
                        return AsyncThrowingStream { self.continuation = $0 }
                    },
                    end: {
                        self.events.append("speech.end")
                        self.continuation?.finish()
                        if self.endThrows { throw VoiceSessionError.notStarted }
                        if self.endHangs { try? await Task.sleep(for: .seconds(3600)) }
                        return self.finals
                    },
                    cancel: {
                        self.events.append("speech.cancel")
                        self.speechCancelled = true
                    }),
                hotKey: VoiceTaskCaptureCoordinator.HotKeySeam(
                    register: { registration }, bind: { _, _ in }),
                insert: { text, target in
                    self.events.append("insert")
                    self.insertedText = text
                    _ = target
                    if let waiter = self.insertGateWaiter {
                        await withCheckedContinuation { waiter($0) }
                    }
                    return self.insertOutcome
                },
                onFinalTranscript: { self.offeredTranscripts.append($0) },
                pill: .none(),
                finalizeTimeout: 0.05,
                now: { clock.next() })
        }
    }

    /// Press, stream segments, release after `hold` seconds, await finalize.
    private func dictate(
        _ coordinator: SystemDictationCoordinator,
        harness: Harness,
        during: [VoiceTranscriptSegment] = []
    ) async {
        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        for segment in during { harness.continuation?.yield(segment) }
        coordinator.endDictation()
        await coordinator.finalizeTask?.value
    }

    // MARK: - Sequencing

    func test_press_snapshotsTheTargetBeforeSpeechStarts() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        XCTAssertEqual(harness.events.first, "snapshot", "the target is captured before any audio starts")
        XCTAssertTrue(harness.events.firstIndex(of: "snapshot")! < harness.events.firstIndex(of: "speech.begin")!)
    }

    // MARK: - Live display

    func test_provisionalSegments_driveTheLiveTranscript() async {
        let harness = Harness(target: target())
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        harness.continuation?.yield(seg("a", "hel", final: false))
        harness.continuation?.yield(seg("a", "hello", final: false))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(coordinator.phase, .listening)
        XCTAssertEqual(coordinator.liveTranscript, "hello")
        XCTAssertNil(harness.insertedText, "provisional text never inserts")
    }

    // MARK: - Insertion

    func test_release_insertsTheFinalTranscript_withContextualWhitespace() async {
        let harness = Harness(target: target())   // preceding "o" is a word character
        harness.finals = [seg("a", "hello", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        XCTAssertEqual(harness.insertedText, " hello", "word-adjacent insertion gains a leading space")
        XCTAssertEqual(coordinator.phase, .inserted)
    }

    func test_shortHold_cancelsWithoutInserting() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        let coordinator = harness.makeCoordinator(
            clock: Clock([t0, t0.addingTimeInterval(0.1)]))

        await dictate(coordinator, harness: harness)

        XCTAssertNil(harness.insertedText)
        XCTAssertTrue(harness.speechCancelled)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: - Refusals & recovery

    func test_secureField_isRefusedAtPress_beforeSpeechStarts() async {
        let harness = Harness(target: target(secure: true))
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()

        guard case .denied = coordinator.phase else {
            return XCTFail("expected denied, got \(coordinator.phase)")
        }
        XCTAssertFalse(harness.events.contains("speech.begin"), "no audio near password fields")
    }

    func test_missingAccessibilityPermission_isDenied() async {
        let harness = Harness(target: target())
        harness.snapshotResult = .failure(.accessibilityPermissionMissing)
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()

        guard case .denied = coordinator.phase else {
            return XCTFail("expected denied, got \(coordinator.phase)")
        }
    }

    func test_noFocusedField_isRecoverable() async {
        let harness = Harness(target: target())
        harness.snapshotResult = .failure(.noFocusedTextElement)
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()

        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
    }

    func test_changedFocus_isRecoverable_andPreservesTheTranscript() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello world", final: true)]
        harness.insertOutcome = .recoverable("The text field lost focus before the transcript was ready.")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
        XCTAssertEqual(coordinator.recoveredTranscript, "hello world", "the words are never lost")
    }

    func test_speechError_withNothingStable_isRecoverable() async {
        let harness = Harness(target: target())
        harness.endThrows = true
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
        XCTAssertNil(harness.insertedText)
    }

    // MARK: - Mid-hold failures & stale-task isolation (review fixes)

    func test_speechFailureMidHold_stopsTheFeed_andPreservesStableText() async {
        let harness = Harness(target: target())
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        harness.continuation?.yield(seg("a", "hello world", final: true))
        for _ in 0..<10 { await Task.yield() }
        harness.continuation?.finish(throwing: VoiceSessionError.audioFormatUnavailable)
        for _ in 0..<25 { await Task.yield() }

        XCTAssertTrue(harness.speechCancelled, "the mic feed must never stay hot after a failure")
        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
        XCTAssertEqual(coordinator.recoveredTranscript, "hello world", "stable text survives the failure")
    }

    func test_newHoldDuringInsert_isNeverClobberedByTheStaleFinalize() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "first sentence", final: true)]
        var gate: CheckedContinuation<Void, Never>?
        harness.insertGateWaiter = { gate = $0 }
        let coordinator = harness.makeCoordinator(
            clock: Clock([t0, t0.addingTimeInterval(2), t0.addingTimeInterval(10)]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        coordinator.endDictation()
        // Let the finalize task reach the gated insert (phase .inserting).
        for _ in 0..<25 { await Task.yield() }
        XCTAssertEqual(coordinator.phase, .inserting)

        // A new hold starts while the old insert is still in flight.
        harness.insertGateWaiter = nil
        coordinator.beginDictation()
        await Task.yield()
        XCTAssertEqual(coordinator.phase, .listening)

        // The stale finalize resumes — it must not touch the new hold.
        gate?.resume()
        await coordinator.finalizeTask?.value
        for _ in 0..<25 { await Task.yield() }

        XCTAssertEqual(coordinator.phase, .listening, "a stale finalize must never stomp a live hold")
    }

    func test_releaseAfterCursorMoved_recoversInsteadOfInserting() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        // The cursor moved within the same field during the hold.
        harness.snapshotResult = .success(FocusedTextTarget(
            applicationPID: 42,
            elementIdentifier: "42#token#AXTextField#Notes",
            selectedRange: NSRange(location: 9, length: 0),
            precedingCharacter: "x",
            followingCharacter: nil,
            isSecure: false))
        coordinator.endDictation()
        await coordinator.finalizeTask?.value

        XCTAssertNil(harness.insertedText, "a moved cursor means the snapshot no longer holds")
        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
        XCTAssertEqual(coordinator.recoveredTranscript, "hello")
    }

    // MARK: - A hold must always end (ported from the capture coordinator)

    func test_hungFinalization_recoversTheStableTextInsteadOfStranding() async {
        let harness = Harness(target: target())
        harness.endHangs = true   // analyzer never finishes its result stream
        let coordinator = harness.makeCoordinator(
            clock: Clock([t0, t0.addingTimeInterval(2)]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        harness.continuation?.yield(seg("a", "hello world", final: true))
        for _ in 0..<10 { await Task.yield() }
        coordinator.endDictation()
        await coordinator.finalizeTask?.value

        XCTAssertNotEqual(coordinator.phase, .listening, "the pill must never strand")
        XCTAssertTrue(harness.speechCancelled, "a wedged analyzer is torn down so the mic is released")
        XCTAssertEqual(
            harness.insertedText, " hello world",
            "the words already transcribed are still inserted")
    }

    func test_dismiss_clearsAStuckPill_andReleasesTheMic() async {
        let harness = Harness(target: target())
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.activate()
        await coordinator.activationTask?.value
        coordinator.beginDictation()
        await Task.yield()
        XCTAssertEqual(coordinator.phase, .listening)

        coordinator.dismiss()
        await coordinator.finalizeTask?.value

        XCTAssertEqual(coordinator.phase, .idle, "there is always a way out")
        XCTAssertTrue(harness.speechCancelled)
        XCTAssertNil(harness.insertedText, "dismissing inserts nothing")
    }

    // MARK: - Retry from recovery (the pill's "Try Current Field")

    func test_retryIntoCurrentField_insertsThePreservedTranscript() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello world", final: true)]
        harness.insertOutcome = .recoverable("The text field lost focus before the transcript was ready.")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)
        guard case .recoverable = coordinator.phase else {
            return XCTFail("precondition: expected recoverable, got \(coordinator.phase)")
        }

        // The user focuses a new field and clicks Try Current Field.
        harness.insertOutcome = .insertedDirectly
        coordinator.retryIntoCurrentField()
        await coordinator.finalizeTask?.value

        XCTAssertEqual(coordinator.phase, .inserted)
        XCTAssertEqual(harness.insertedText, " hello world", "whitespace re-normalizes against the fresh snapshot")
    }

    func test_retryIntoCurrentField_withoutARecoveredTranscript_doesNothing() async {
        let harness = Harness(target: target())
        let coordinator = harness.makeCoordinator(clock: Clock([t0]))

        coordinator.retryIntoCurrentField()
        await coordinator.finalizeTask?.value

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(harness.insertedText)
    }

    func test_retryIntoCurrentField_refusesASecureTarget() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        harness.insertOutcome = .recoverable("lost focus")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        // Focus moved to a password field before the retry.
        harness.snapshotResult = .success(target(secure: true))
        harness.insertOutcome = .insertedDirectly
        harness.insertedText = nil
        coordinator.retryIntoCurrentField()
        await coordinator.finalizeTask?.value

        XCTAssertNil(harness.insertedText, "secure fields never receive dictation, retries included")
        XCTAssertEqual(coordinator.recoveredTranscript, "hello", "the words survive the refusal")
    }

    // MARK: - Clip history (notch shelf spec §1 / §3, 2026-08-12)

    func test_finalTranscript_isOfferedToClipHistoryOnInsert() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello world", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        XCTAssertEqual(coordinator.phase, .inserted)
        XCTAssertEqual(
            harness.offeredTranscripts, ["hello world"],
            "the words as spoken reach history exactly once — not the target-specific normalization")
        XCTAssertEqual(harness.insertedText, " hello world")
    }

    func test_secureFieldTranscript_isNeverOffered() async {
        // Secure targets are refused at press, before any audio: nothing is
        // transcribed, so nothing can be stored. (`DictationWhitespace.insertion`
        // returning nil is the second, defensive gate the offer sits behind.)
        let harness = Harness(target: target(secure: true))
        harness.finals = [seg("a", "hunter2", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        XCTAssertTrue(harness.offeredTranscripts.isEmpty, "password fields never reach clip history")
        XCTAssertNil(harness.insertedText)
    }

    func test_retryIntoSecureField_neitherInsertsNorOffers() async {
        // The whitespace nil-guard on the retry path: the transcript exists and
        // is preserved, but the field is secure — it must not be stored either.
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        harness.insertOutcome = .recoverable("lost focus")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)
        harness.offeredTranscripts = []   // ignore the first capture's offer

        harness.snapshotResult = .success(target(secure: true))
        harness.insertOutcome = .insertedDirectly
        harness.insertedText = nil
        coordinator.retryIntoCurrentField()
        await coordinator.finalizeTask?.value

        XCTAssertNil(harness.insertedText)
        XCTAssertTrue(harness.offeredTranscripts.isEmpty, "a secure retry stores nothing, anywhere")
    }

    func test_preservedTranscript_isStillOffered() async {
        // Insertion failed and the words live only in the pill — history is
        // exactly where they must not be lost from.
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello world", final: true)]
        harness.insertOutcome = .recoverable("The text field lost focus before the transcript was ready.")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        guard case .recoverable = coordinator.phase else {
            return XCTFail("expected recoverable, got \(coordinator.phase)")
        }
        XCTAssertEqual(harness.offeredTranscripts, ["hello world"])
    }

    func test_retryAfterFailure_doesNotOfferTheTranscriptTwice() async {
        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello world", final: true)]
        harness.insertOutcome = .recoverable("The text field lost focus before the transcript was ready.")
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)
        XCTAssertEqual(harness.offeredTranscripts.count, 1, "precondition: offered once by the first attempt")

        harness.insertOutcome = .insertedDirectly
        coordinator.retryIntoCurrentField()
        await coordinator.finalizeTask?.value

        XCTAssertEqual(coordinator.phase, .inserted)
        XCTAssertEqual(
            harness.offeredTranscripts, ["hello world"],
            "a retry re-inserts the same words — it must not create a second history entry")
    }

    // MARK: - Hotkey & data isolation

    func test_hotKeyConflict_isSurfaced() async {
        let harness = Harness(target: target())
        let coordinator = harness.makeCoordinator(
            clock: Clock([t0]), registration: .conflict(-9878))

        coordinator.activate()
        await coordinator.activationTask?.value

        XCTAssertEqual(coordinator.hotKeyRegistration, .conflict(-9878))
    }

    func test_fullCycle_neverTouchesSwiftData() async throws {
        // The coordinator's API takes no ModelContext at all; a full successful
        // cycle runs while a store exists and leaves it untouched.
        let container = try ModelContainer(
            for: MustardTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let harness = Harness(target: target())
        harness.finals = [seg("a", "hello", final: true)]
        let coordinator = harness.makeCoordinator(clock: Clock([t0, t0.addingTimeInterval(2)]))

        await dictate(coordinator, harness: harness)

        XCTAssertEqual(coordinator.phase, .inserted)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).count, 0)
    }
}
