import XCTest
import SwiftData
@testable import MustardKit

/// The notch-adjacent quick editor's state (Capture Task 4, BAK-284): field
/// revisions, key/dismissal decisions, commit/close semantics, Open Fully
/// dispatch, and the controller's one-visible-card replacement. Panel-less —
/// the NSPanel never exists in tests.
@MainActor
final class VoiceTaskQuickEditStateTests: XCTestCase {

    // MARK: - Fixtures

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func capturedTask(in context: ModelContext) -> MustardTask {
        let task = MustardTask(title: "Buy milk")
        task.source = "voice"
        task.captureState = .raw
        task.captureTranscript = "buy milk"
        context.insert(task)
        try? context.save()
        return task
    }

    private func makeState(
        task: MustardTask, context: ModelContext, navigation: NotchNavigation? = nil
    ) -> VoiceTaskQuickEditState {
        VoiceTaskQuickEditState(task: task, context: context, navigation: navigation)
    }

    // MARK: - Revisions

    func test_userChanged_bumpsOnlyThatField() throws {
        let context = try ctx()
        let state = makeState(task: capturedTask(in: context), context: context)

        state.userChanged(.title)
        state.userChanged(.title)
        state.userChanged(.notes)

        XCTAssertEqual(state.revisions[.title], 2)
        XCTAssertEqual(state.revisions[.notes], 1)
        for field in [VoiceTaskField.area, .schedule, .urls] {
            XCTAssertEqual(state.revisions[field], 0, "\(field) must be untouched")
        }
    }

    // MARK: - Key & dismissal decisions (pure)

    func test_plainReturn_inNotes_insertsNewline() {
        XCTAssertEqual(
            VoiceTaskQuickEditState.action(for: .plainReturn(in: .notes)),
            .insertNewline)
    }

    func test_plainReturn_inTitle_commits() {
        XCTAssertEqual(
            VoiceTaskQuickEditState.action(for: .plainReturn(in: .title)),
            .commit)
    }

    func test_commandReturn_commitsAnywhere() {
        XCTAssertEqual(VoiceTaskQuickEditState.action(for: .commandReturn), .commit)
    }

    func test_escape_dismisses() {
        XCTAssertEqual(VoiceTaskQuickEditState.action(for: .escape), .dismiss)
    }

    func test_outsideClick_commits() {
        XCTAssertEqual(VoiceTaskQuickEditState.action(for: .outsideClick), .commit)
    }

    // MARK: - Commit / close semantics

    func test_seedsDraftFromTask() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        task.notes = "some notes"
        task.links = [TaskLink(label: "coles.com.au", url: "https://coles.com.au")]

        let state = makeState(task: task, context: context)

        XCTAssertEqual(state.draft.title, "Buy milk")
        XCTAssertEqual(state.draft.notes, "some notes")
        XCTAssertEqual(state.draft.urls, [URL(string: "https://coles.com.au")!])
    }

    func test_commit_appliesDraftToTaskAndCloses() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.draft.title = "Buy oat milk"
        state.userChanged(.title)
        state.draft.notes = "from the good shop"
        state.userChanged(.notes)
        state.draft.urls = [URL(string: "https://coles.com.au")!]
        state.userChanged(.urls)
        state.handle(.commandReturn)

        XCTAssertEqual(task.title, "Buy oat milk")
        XCTAssertEqual(task.notes, "from the good shop")
        XCTAssertEqual(task.links.map(\.url), ["https://coles.com.au"])
        XCTAssertTrue(state.isClosed)
    }

    func test_commit_stampsAnExistingAreaByName() throws {
        let context = try ctx()
        let area = Area(name: "Code Heroes")
        context.insert(area)
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.draft.areaName = "Code Heroes"
        state.userChanged(.area)
        state.handle(.commandReturn)

        XCTAssertEqual(task.list?.area?.name, "Code Heroes")
    }

    func test_escape_keepsTheTaskAndPendingEditsUnapplied() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.draft.title = "Something else"
        state.userChanged(.title)
        state.handle(.escape)

        XCTAssertEqual(task.title, "Buy milk", "Escape must not apply pending edits")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MustardTask>()).count, 1,
            "Escape keeps the task — capture is never destructive")
        XCTAssertTrue(state.isClosed)
    }

    func test_coordinatorApply_updatesDraftWithoutClosing() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.apply(VoiceTaskDraft(title: "Buy milk from Coles", notes: "generated"))

        XCTAssertEqual(state.draft.title, "Buy milk from Coles")
        XCTAssertEqual(state.draft.notes, "generated")
        XCTAssertFalse(state.isClosed)
    }

    // MARK: - Open Fully

    func test_openFully_commitsAndDispatchesToTheMainWindow() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let navigation = NotchNavigation()
        let state = makeState(task: task, context: context, navigation: navigation)

        state.draft.title = "Buy oat milk"
        state.userChanged(.title)
        state.openFully()

        XCTAssertIdentical(navigation.pendingTask, task, "Open Fully hands off to the task drawer")
        XCTAssertEqual(task.title, "Buy oat milk", "edits ride along into the full editor")
        XCTAssertTrue(state.isClosed)
    }

    // MARK: - Discard

    func test_discard_deletesTheCapturedTask() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.discard()

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MustardTask>()).count, 0,
            "an accidental capture must be removable, not just closeable")
        XCTAssertTrue(state.isClosed)
    }

    func test_close_stillKeepsTheTask() throws {
        let context = try ctx()
        let task = capturedTask(in: context)
        let state = makeState(task: task, context: context)

        state.handle(.escape)

        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).count, 1)
        XCTAssertIdentical(try context.fetch(FetchDescriptor<MustardTask>()).first, task)
    }

    // MARK: - One visible card

    func test_present_replacesThePreviousCard() throws {
        let context = try ctx()
        let controller = VoiceTaskQuickEditController(
            context: context, navigation: nil, presentsPanel: false)

        let first = controller.present(for: capturedTask(in: context))
        let second = controller.present(for: capturedTask(in: context))

        XCTAssertTrue(first.isClosed, "a new capture replaces the visible card")
        XCTAssertFalse(second.isClosed)
    }
}
