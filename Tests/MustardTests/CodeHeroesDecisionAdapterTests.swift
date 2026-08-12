import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class CodeHeroesDecisionAdapterTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func test_importProjectsEligibleClusterWithBoundedMetadataAndLocalLinks() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, fileManager: .default, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertTrue(report.readOnly)
        XCTAssertEqual(report.repositoryWrites, 0)
        let task = try XCTUnwrap(try tasks(context).first)
        XCTAssertEqual(task.uid, "codeheroes:decision:DL-1")
        XCTAssertEqual(task.createdAt, fixedNow)
        XCTAssertEqual(task.source, CodeHeroesDecisionPolicy.source)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .needsInput)
        XCTAssertEqual(task.list?.area?.name, "Digital Licence")
        XCTAssertEqual(task.list?.name, "Digital Licence")
        XCTAssertEqual(task.links.map(\.label), ["Queue", "Run", "Decision"])
        XCTAssertTrue(task.links.allSatisfy { $0.url.hasPrefix(fixture.root.standardizedFileURL.path) })
        XCTAssertTrue(task.sourceContext.contains("digest="))
        XCTAssertNil(task.actionTypeRaw); XCTAssertNil(task.confidence); XCTAssertNil(task.delegation); XCTAssertNil(task.agentRun)
    }

    func test_fatalQueueFailureDoesNotMutateSwiftData() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        try Data("{ not json".utf8).write(to: fixture.queueURL)
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.findings.first?.scope, .queue)
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_invalidClusterSkipsOnlyThatClusterAndImportsOtherClusters() throws {
        let fixture = try Fixture(clusters: [Fixture.cluster("DL-1"), Fixture.cluster("BAD", project: "unknown")])
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.clusterID, "BAD")
        XCTAssertEqual(try tasks(context).count, 1)
    }

    func test_identicalQueueIsIdempotentAndChangedQueueUpdatesAdapterOwnedFields() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        XCTAssertEqual(adapter.importQueue(at: fixture.queueURL).createdCount, 1)
        let original = try XCTUnwrap(try tasks(context).first)
        let originalCreatedAt = original.createdAt

        let unchanged = adapter.importQueue(at: fixture.queueURL)
        XCTAssertEqual(unchanged.unchangedCount, 1)
        XCTAssertEqual(unchanged.updatedCount, 0)

        try fixture.writeQueue(clusters: [Fixture.cluster("DL-1", title: "Changed title")])
        let changed = adapter.importQueue(at: fixture.queueURL)
        XCTAssertEqual(changed.updatedCount, 1)
        XCTAssertEqual(original.title, "Changed title")
        XCTAssertEqual(original.createdAt, originalCreatedAt)
    }

    func test_newerQueueMarksAbsentProjectionStaleWithoutTouchingOtherSources() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = adapter.importQueue(at: fixture.queueURL)
        let manual = MustardTask(title: "Personal")
        context.insert(manual)
        try context.save()

        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")])
        let report = adapter.importQueue(at: fixture.queueURL)

        let stale = try XCTUnwrap(try tasks(context).first { $0.uid == "codeheroes:decision:DL-1" })
        XCTAssertEqual(stale.stage, .needsReview)
        XCTAssertTrue(stale.tags.contains("source-stale"))
        XCTAssertEqual(report.staleCount, 1)
        XCTAssertEqual(manual.title, "Personal")
    }

    func test_foreignUIDCollisionIsReportedWithoutChangingForeignTask() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let foreign = MustardTask(title: "Do not touch")
        foreign.uid = "codeheroes:decision:DL-1"
        context.insert(foreign)
        try context.save()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.collisionCount, 1)
        XCTAssertEqual(foreign.title, "Do not touch")
        XCTAssertEqual(foreign.source, "manual")
    }

    func test_escapedSymlinkDecisionSourceSkipsClusterWithoutMutatingTasks() throws {
        let fixture = try Fixture()
        let escaped = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "# DEC-DL-1".write(to: escaped, atomically: true, encoding: .utf8)
        let local = fixture.root.appendingPathComponent("operations/decisions/open/DEC-DL-1.md")
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: escaped)
        defer { try? FileManager.default.removeItem(at: escaped) }
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.reason, "Missing or escaped decision source")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_escapedDecisionSourceDirectorySymlinkSkipsClusterWithoutExternalLink() throws {
        let fixture = try Fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# DEC-DL-1".write(to: outside.appendingPathComponent("DEC-DL-1.md"), atomically: true, encoding: .utf8)
        let localDirectory = fixture.root.appendingPathComponent("operations/decisions/open")
        try FileManager.default.removeItem(at: localDirectory)
        try FileManager.default.createSymbolicLink(at: localDirectory, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.reason, "Missing or escaped decision source")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_injectedFileManagerReadFailureIsReportedWithoutModelMutation() throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, fileManager: FailingReadFileManager(), now: { self.fixedNow })

        let report = adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.findings.first?.reason, "Unable to read queue file")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: Area.self, TaskList.self, MustardTask.self, Recommendation.self, AgentRun.self, AgentMessage.self, CalendarEvent.self, configurations: configuration))
    }

    private func tasks(_ context: ModelContext) throws -> [MustardTask] { try context.fetch(FetchDescriptor<MustardTask>()) }
}

private final class FailingReadFileManager: FileManager {
    override func contents(atPath path: String) -> Data? { nil }
}

private final class Fixture {
    let root: URL
    let queueURL: URL
    private let receipt = "operations/receipts/RUN-1.md"

    init(clusters: [CodeHeroesDecisionQueue.Cluster] = [Fixture.cluster("DL-1")]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        queueURL = root.appendingPathComponent("operations/decision-queue.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("operations/decisions/open"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("operations/receipts"), withIntermediateDirectories: true)
        try "receipt".write(to: root.appendingPathComponent(receipt), atomically: true, encoding: .utf8)
        for id in Set(clusters.flatMap(\.sourceDecisionIDs)) {
            try "# \(id)".write(to: root.appendingPathComponent("operations/decisions/open/\(id).md"), atomically: true, encoding: .utf8)
        }
        try writeQueue(clusters: clusters)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func cluster(_ id: String, project: String = "dl", title: String = "Decision") -> CodeHeroesDecisionQueue.Cluster {
        .init(clusterID: id, projectID: project, title: title, triageState: "needs-human-decision", mustardStage: "needsInput", priority: "high", decisionRequired: true, humanActionRequired: true, question: "Question", nextAction: "Next", whyGrouped: "Why", sourceDecisionIDs: ["DEC-\(id)"])
    }

    func writeQueue(clusters: [CodeHeroesDecisionQueue.Cluster]) throws {
        let document = CodeHeroesDecisionQueue.Document(schemaVersion: 1, reportType: "dream_decision_triage", generatedAt: "2026-01-01T00:00:00Z", sourceRunID: "RUN-1", sourceReceipt: receipt, canonicalInput: "operations/input.md", readOnly: true, decisionStatusMutations: 0, mustardImport: "future-adapter-only", summary: [:], historicalOpenDecisionIDs: [], historicalExclusions: [], queue: clusters)
        try JSONEncoder().encode(document).write(to: queueURL)
    }
}
