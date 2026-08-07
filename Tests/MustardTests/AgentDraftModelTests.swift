import XCTest
import SwiftData
@testable import MustardKit

final class AgentDraftModelTests: XCTestCase {
    @MainActor
    func test_draftRoundTripsThroughRun() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self, configurations: config)
        let context = ModelContext(container)
        let task = MustardTask(title: "Prep")
        let run = AgentRun(task: task)
        let draft = AgentDraft(run: run, kind: .comment, title: "Jira reply",
                               relativePath: "_agent/drafts/u1/reply.md")
        context.insert(task); context.insert(run); context.insert(draft)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<AgentRun>()).first)
        XCTAssertEqual(fetched.drafts?.count, 1)
        XCTAssertEqual(fetched.drafts?.first?.kind, .comment)
        XCTAssertEqual(fetched.drafts?.first?.relativePath, "_agent/drafts/u1/reply.md")
    }

    func test_kindDefaultsToOtherForUnknownRaw() {
        let draft = AgentDraft()
        draft.kindRaw = "unknown"
        XCTAssertEqual(draft.kind, .other)
    }
}
