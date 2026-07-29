import XCTest
import SwiftData
@testable import MustardKit

/// The modern capture coordinator (Capture Task 3, BAK-283): hotkey press →
/// segment stream → release → raw Inbox task → editor seam → on-device
/// drafting → revision-gated merge. Everything is stubbed — speech, hotkey,
/// model, editor — and time is injected; no microphone, panel, or clock.
@MainActor
final class VoiceTaskCaptureCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func seg(_ id: String, _ text: String, start: Double, final: Bool) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: start + 1,
            isFinal: final, confidence: nil, source: .microphone)
    }

    private let t0 = Date(timeIntervalSince1970: 1_784_714_400)

    /// A settable clock: `beginCapture` reads element 0, `endCapture` element 1.
    private final class Clock {
        var times: [Date]
        private var index = 0
        init(_ times: [Date]) { self.times = times }
        func next() -> Date {
            defer { index = min(index + 1, times.count - 1) }
            return times[index]
        }
    }

    private final class StubSpeech {
        var continuation: AsyncThrowingStream<VoiceTranscriptSegment, Error>.Continuation?
        var finals: [VoiceTranscriptSegment] = []
        var cancelled = false
        var authorized = true

        var seam: VoiceTaskCaptureCoordinator.Speech {
            VoiceTaskCaptureCoordinator.Speech(
                authorize: { self.authorized },
                begin: { AsyncThrowingStream { self.continuation = $0 } },
                end: {
                    self.continuation?.finish()
                    return self.finals
                },
                cancel: { self.cancelled = true })
        }
    }

    private final class StubEditor: VoiceTaskQuickEditing {
        var draft: VoiceTaskDraft
        var revisions = VoiceTaskFieldRevisions()
        var applied: VoiceTaskDraft?
        var closed = false
        init(draft: VoiceTaskDraft) { self.draft = draft }
        func apply(_ merged: VoiceTaskDraft) { applied = merged; draft = merged }
        func close() { closed = true }
    }

    /// Holds the drafting request until the test releases it.
    private actor DraftGate {
        private var continuation: CheckedContinuation<Result<VoiceTaskDraft, VoiceTaskDraftFailure>, Never>?
        func wait() async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure> {
            await withCheckedContinuation { continuation = $0 }
        }
        func resume(_ result: Result<VoiceTaskDraft, VoiceTaskDraftFailure>) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private func makeCoordinator(
        context: ModelContext,
        speech: StubSpeech,
        clock: Clock,
        registration: HotKeyRegistration = .registered,
        draft: @escaping (String, [String], Date) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure> = { _, _, _ in
            .failure(.model(.unavailable("not wired")))
        },
        presentEditor: @escaping (MustardTask) -> (any VoiceTaskQuickEditing)? = { _ in nil }
    ) -> VoiceTaskCaptureCoordinator {
        VoiceTaskCaptureCoordinator(
            context: context,
            speech: speech.seam,
            hotKey: VoiceTaskCaptureCoordinator.HotKeySeam(
                register: { registration }, bind: { _, _ in }),
            pill: .none(),
            draft: draft,
            allowedAreas: { ["Code Heroes", "Personal"] },
            presentEditor: presentEditor,
            now: { clock.next() })
    }

    private func tasks(in context: ModelContext) throws -> [MustardTask] {
        try context.fetch(FetchDescriptor<MustardTask>())
    }

    /// Activate (authorize), press, stream `during` segments, release, and
    /// wait for finalization. Drafting completion is awaited by callers that
    /// need it — some tests gate it deliberately.
    private func capture(
        _ coordinator: VoiceTaskCaptureCoordinator,
        speech: StubSpeech,
        during: [VoiceTranscriptSegment] = []
    ) async {
        if coordinator.activationTask == nil {
            coordinator.activate()
        }
        await coordinator.activationTask?.value
        coordinator.beginCapture()
        await Task.yield()
        for segment in during { speech.continuation?.yield(segment) }
        coordinator.endCapture()
        await coordinator.finalizeTask?.value
    }

    // MARK: - Commit semantics

    func test_provisionalSegments_neverInsertATask() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        let coordinator = makeCoordinator(context: context, speech: speech, clock: Clock([t0]))
        coordinator.activate()
        await coordinator.activationTask?.value

        coordinator.beginCapture()
        await Task.yield()
        speech.continuation?.yield(seg("a", "buy mi", start: 0, final: false))
        speech.continuation?.yield(seg("a", "buy milk", start: 0, final: false))
        // Let the consume task drain the stream.
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(try tasks(in: context).count, 0, "provisional text must never commit")
        XCTAssertEqual(coordinator.liveTranscript, "buy milk")
        XCTAssertEqual(coordinator.phase, .recording)
    }

    func test_release_commitsExactlyOneRawTask_withVerbatimTranscript() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [
            seg("a", "buy milk", start: 0, final: true),
            seg("b", "and eggs", start: 2, final: true),
        ]
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            clock: Clock([t0, t0.addingTimeInterval(2)]))

        await capture(coordinator, speech: speech)

        let all = try tasks(in: context)
        XCTAssertEqual(all.count, 1, "final text commits exactly once")
        let task = try XCTUnwrap(all.first)
        XCTAssertEqual(task.title, "Buy milk and eggs")
        XCTAssertEqual(task.captureTranscript, "buy milk and eggs", "raw transcript is verbatim")
        XCTAssertEqual(task.source, "voice")
        XCTAssertEqual(coordinator.phase, .committed("Buy milk and eggs"))
    }

    func test_shortHold_cancels_andDiscardsRecognition() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [seg("a", "buy milk", start: 0, final: true)]
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            clock: Clock([t0, t0.addingTimeInterval(0.1)]))

        await capture(coordinator, speech: speech)

        XCTAssertEqual(try tasks(in: context).count, 0)
        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertTrue(speech.cancelled)
    }

    func test_deniedAuthorization_neverRecords() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.authorized = false
        let coordinator = makeCoordinator(context: context, speech: speech, clock: Clock([t0]))
        coordinator.activate()
        await coordinator.activationTask?.value

        coordinator.beginCapture()

        XCTAssertEqual(coordinator.phase, .denied)
        XCTAssertEqual(try tasks(in: context).count, 0)
    }

    // MARK: - Drafting

    func test_draftingFailure_leavesRawUsableTask() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [seg("a", "buy milk", start: 0, final: true)]
        let editor = StubEditor(draft: VoiceTaskDraft(title: "Buy milk"))
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            clock: Clock([t0, t0.addingTimeInterval(2)]),
            draft: { _, _, _ in .failure(.model(.modelNotReady)) },
            presentEditor: { _ in editor })

        await capture(coordinator, speech: speech)
        await coordinator.draftingTask?.value

        let task = try XCTUnwrap(try tasks(in: context).first)
        XCTAssertEqual(task.captureState, .raw, "a failed draft stays raw and retryable")
        XCTAssertEqual(task.title, "Buy milk")
        XCTAssertFalse(editor.closed, "the editor keeps the raw text visible")
        XCTAssertNil(editor.applied)
    }

    func test_draftingSuccess_mergesAppliesAndMarksCleaned() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [seg("a", "buy milk from coles for code heroes", start: 0, final: true)]
        let editor = StubEditor(draft: VoiceTaskDraft(title: "Buy milk from coles for code heroes"))
        let generated = VoiceTaskDraft(
            title: "Buy milk from Coles",
            notes: "For the office",
            areaName: "Code Heroes",
            urls: [URL(string: "https://coles.com.au")!])
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            clock: Clock([t0, t0.addingTimeInterval(2)]),
            draft: { _, _, _ in .success(generated) },
            presentEditor: { _ in editor })

        await capture(coordinator, speech: speech)
        await coordinator.draftingTask?.value

        let task = try XCTUnwrap(try tasks(in: context).first)
        XCTAssertEqual(task.title, "Buy milk from Coles")
        XCTAssertEqual(task.notes, "For the office")
        XCTAssertEqual(task.captureState, .cleaned)
        XCTAssertEqual(task.links.map(\.url), ["https://coles.com.au"])
        XCTAssertEqual(task.list?.area?.name, "Code Heroes")
        XCTAssertEqual(editor.applied?.title, "Buy milk from Coles")
        XCTAssertEqual(
            task.captureTranscript, "buy milk from coles for code heroes",
            "cleanup must never touch the verbatim transcript")
    }

    func test_userEditAfterRequest_winsOverGeneratedField() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [seg("a", "buy milk", start: 0, final: true)]
        let editor = StubEditor(draft: VoiceTaskDraft(title: "Buy milk"))
        let gate = DraftGate()
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            clock: Clock([t0, t0.addingTimeInterval(2)]),
            draft: { _, _, _ in await gate.wait() },
            presentEditor: { _ in editor })

        await capture(coordinator, speech: speech)

        // Leon edits the title while the model is still thinking.
        editor.draft.title = "Buy oat milk"
        editor.revisions.bump(.title)

        await gate.resume(.success(VoiceTaskDraft(title: "Buy milk from Coles", notes: "Generated note")))
        await coordinator.draftingTask?.value

        let task = try XCTUnwrap(try tasks(in: context).first)
        XCTAssertEqual(task.title, "Buy oat milk", "a late generated title must not overwrite a user edit")
        XCTAssertEqual(task.notes, "Generated note", "untouched fields still receive generated values")
        XCTAssertEqual(editor.applied?.title, "Buy oat milk")
    }

    // MARK: - Editor lifecycle

    func test_secondCapture_closesThePreviousEditor() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        speech.finals = [seg("a", "buy milk", start: 0, final: true)]
        var editors: [StubEditor] = []
        let coordinator = makeCoordinator(
            context: context, speech: speech,
            // Three reads per capture: press, release, drafting-request.
            clock: Clock([
                t0, t0.addingTimeInterval(2), t0.addingTimeInterval(2),
                t0.addingTimeInterval(10), t0.addingTimeInterval(12), t0.addingTimeInterval(12),
            ]),
            presentEditor: { _ in
                let editor = StubEditor(draft: VoiceTaskDraft(title: "Buy milk"))
                editors.append(editor)
                return editor
            })

        await capture(coordinator, speech: speech)
        speech.finals = [seg("b", "and eggs", start: 0, final: true)]
        await capture(coordinator, speech: speech)

        XCTAssertEqual(editors.count, 2)
        XCTAssertTrue(editors[0].closed, "a second capture closes the previous editor")
        XCTAssertFalse(editors[1].closed)
        XCTAssertEqual(try tasks(in: context).count, 2)
    }

    // MARK: - Hotkey registration

    func test_hotKeyConflict_isSurfaced() async throws {
        let context = try ctx()
        let speech = StubSpeech()
        let coordinator = makeCoordinator(
            context: context, speech: speech, clock: Clock([t0]),
            registration: .conflict(-9878))

        coordinator.activate()
        await coordinator.activationTask?.value

        XCTAssertEqual(coordinator.hotKeyRegistration, .conflict(-9878), "registration must never fail silently")
    }
}
