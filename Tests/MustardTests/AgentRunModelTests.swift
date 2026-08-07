import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class AgentRunModelTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self,
            configurations: configuration
        )
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try makeContainer())
    }

    func test_persistsTaskRunAndMessagesInSequenceOrder() throws {
        let context = try makeContext()
        let task = MustardTask(title: "Prep release")
        let run = AgentRun(task: task, workingDirectory: "/kb/DL", project: "DL")
        let question = AgentMessage(
            run: run,
            sequence: 1,
            role: .agent,
            kind: .question,
            content: "Which version?"
        )
        let delegation = AgentMessage(
            run: run,
            sequence: 0,
            role: .human,
            kind: .delegation,
            content: "Prep release"
        )

        context.insert(task)
        context.insert(run)
        context.insert(question)
        context.insert(delegation)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<MustardTask>()).first)
        let fetchedRun = try XCTUnwrap(fetched.agentRun)
        XCTAssertEqual(fetchedRun.state, .queued)
        XCTAssertEqual(fetchedRun.workingDirectory, "/kb/DL")
        XCTAssertEqual(fetchedRun.project, "DL")
        XCTAssertEqual(fetchedRun.orderedMessages.map(\.sequence), [0, 1])
        XCTAssertEqual(fetchedRun.orderedMessages.map(\.content), ["Prep release", "Which version?"])
        XCTAssertTrue(fetchedRun.orderedMessages.allSatisfy { $0.run === fetchedRun })
    }

    func test_unknownRawValuesUseSafeDefaults() {
        let run = AgentRun()
        run.providerRaw = "unknown-provider"
        run.stateRaw = "unknown-state"

        let message = AgentMessage()
        message.roleRaw = "unknown-role"
        message.kindRaw = "unknown-kind"

        XCTAssertEqual(run.provider, .claude)
        XCTAssertEqual(run.state, .queued)
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.kind, .progress)
    }

    func test_orderedMessagesDeterministicallyBreaksSequenceTiesAfterRefetch() throws {
        let container = try makeContainer()
        let writeContext = ModelContext(container)
        let run = AgentRun()
        let later = AgentMessage(run: run, sequence: 4, content: "later")
        later.createdAt = Date(timeIntervalSince1970: 200)
        later.uid = "message-z-later"
        let earlierZ = AgentMessage(run: run, sequence: 4, content: "earlier-z")
        earlierZ.createdAt = Date(timeIntervalSince1970: 100)
        earlierZ.uid = "message-z-earlier"
        let earlierA = AgentMessage(run: run, sequence: 4, content: "earlier-a")
        earlierA.createdAt = Date(timeIntervalSince1970: 100)
        earlierA.uid = "message-a-earlier"

        writeContext.insert(run)
        writeContext.insert(later)
        writeContext.insert(earlierZ)
        writeContext.insert(earlierA)
        try writeContext.save()

        let readContext = ModelContext(container)
        let fetchedRun = try XCTUnwrap(readContext.fetch(FetchDescriptor<AgentRun>()).first)

        XCTAssertEqual(
            fetchedRun.orderedMessages.map(\.content),
            ["earlier-a", "earlier-z", "later"]
        )
    }

    func test_deletingTaskCascadesRunAndMessages() throws {
        let context = try makeContext()
        let task = MustardTask(title: "Prep release")
        let run = AgentRun(task: task)
        let message = AgentMessage(run: run, content: "Prep release")
        context.insert(task)
        context.insert(run)
        context.insert(message)
        try context.save()

        context.delete(task)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<AgentRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AgentMessage>()).isEmpty)
    }
}
