import XCTest
import SwiftData
@testable import MustardKit

/// System-wide dictation coordination (Dictation Task 4, BAK-290): snapshot
/// the focused field BEFORE speech starts, stream provisional text, finalize
/// on release, revalidate + whitespace-normalize + insert — and never touch
/// SwiftData. All seams stubbed; time injected.
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
        var insertOutcome: TextInsertionOutcome = .insertedDirectly
        var insertedText: String?
        var continuation: AsyncThrowingStream<VoiceTranscriptSegment, Error>.Continuation?
        var speechCancelled = false

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
                    return self.insertOutcome
                },
                pill: .none(),
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
