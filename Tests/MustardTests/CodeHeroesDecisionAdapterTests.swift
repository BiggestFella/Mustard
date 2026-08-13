import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class CodeHeroesDecisionAdapterTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func test_fileTypeAndSizeMetadataDoesNotRunOnMainActor() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let fileManager = MetadataThreadRecordingFileManager()
        let adapter = CodeHeroesDecisionAdapter(
            context: context,
            repositoryRoot: fixture.root,
            fileManager: fileManager,
            now: { self.fixedNow }
        )

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 1)
        XCTAssertGreaterThan(fileManager.metadataCallCount, 0)
        XCTAssertFalse(fileManager.didReadMetadataOnMainThread)
    }

    func test_invalidQueueTypeAndOversizeMetadataFailClosedWithoutWrites() async throws {
        let fixture = try Fixture()
        let originalQueue = try Data(contentsOf: fixture.queueURL)
        let cases: [(CodeHeroesDecisionFileAccess.Metadata, String)] = [
            (.init(kind: .directory, size: 0), "Queue path is not a regular file beneath the configured repository root"),
            (.init(kind: .regularFile, size: 5 * 1_024 * 1_024 + 1), "Queue file exceeds the safe size limit"),
        ]

        for (metadata, expectedFinding) in cases {
            let context = try makeContext()
            let access = CodeHeroesDecisionFileAccess(
                normalize: { $0.standardizedFileURL.resolvingSymlinksInPath() },
                metadata: { url in url.lastPathComponent == "decision-queue.json" ? metadata : nil },
                contents: { _ in nil }
            )
            let adapter = CodeHeroesDecisionAdapter(
                context: context,
                repositoryRoot: fixture.root,
                fileAccess: access,
                now: { self.fixedNow }
            )

            let report = await adapter.importQueue(at: fixture.queueURL)

            XCTAssertEqual(report.findings.first?.reason, expectedFinding)
            XCTAssertEqual(report.repositoryWrites, 0)
            XCTAssertEqual(report.externalWrites, 0)
            XCTAssertEqual(try tasks(context).count, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.queueURL), originalQueue)
        }
    }

    func test_importProjectsEligibleClusterWithBoundedMetadataAndLocalLinks() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, fileManager: .default, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

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
        XCTAssertTrue(task.sourceContext.contains("generated_at=2026-01-01T00:00:00Z"))
        XCTAssertNil(task.actionTypeRaw); XCTAssertNil(task.confidence); XCTAssertNil(task.delegation); XCTAssertNil(task.agentRun)
    }

    func test_fatalQueueFailureDoesNotMutateSwiftData() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        try Data("{ not json".utf8).write(to: fixture.queueURL)
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.findings.first?.scope, .queue)
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_invalidClusterSkipsOnlyThatClusterAndImportsOtherClusters() async throws {
        let fixture = try Fixture(clusters: [Fixture.cluster("DL-1"), Fixture.cluster("BAD", project: "unknown")])
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.clusterID, "BAD")
        XCTAssertEqual(try tasks(context).count, 1)
    }

    func test_identicalQueueIsIdempotentAndChangedQueueUpdatesAdapterOwnedFields() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        let initial = await adapter.importQueue(at: fixture.queueURL)
        XCTAssertEqual(initial.createdCount, 1)
        let original = try XCTUnwrap(try tasks(context).first)
        let originalCreatedAt = original.createdAt

        let unchanged = await adapter.importQueue(at: fixture.queueURL)
        XCTAssertEqual(unchanged.unchangedCount, 1)
        XCTAssertEqual(unchanged.updatedCount, 0)

        try fixture.writeQueue(clusters: [Fixture.cluster("DL-1", title: "Changed title")])
        let changed = await adapter.importQueue(at: fixture.queueURL)
        XCTAssertEqual(changed.updatedCount, 1)
        XCTAssertEqual(original.title, "Changed title")
        XCTAssertEqual(original.createdAt, originalCreatedAt)
    }

    func test_repeatedImportKeepsUniqueProjectionUIDsAndStableAttentionSemantics() async throws {
        let needsInput = Fixture.cluster(
            "DL-INPUT", stage: "needsInput", decisionRequired: true, humanActionRequired: false
        )
        let needsReviewEvidence = Fixture.cluster(
            "DL-EVIDENCE", triageState: "needs-evidence", stage: "needsReview",
            decisionRequired: false, humanActionRequired: false
        )
        let manualHumanAction = Fixture.cluster(
            "DL-ACTION", triageState: "manual-action", stage: "needsInput",
            decisionRequired: false, humanActionRequired: true
        )
        let fixture = try Fixture(clusters: [needsInput, needsReviewEvidence, manualHumanAction])
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(
            context: context, repositoryRoot: fixture.root, now: { self.fixedNow }
        )

        let first = await adapter.importQueue(at: fixture.queueURL)
        let firstTasks = try tasks(context)
        XCTAssertEqual(first.createdCount, 3)
        XCTAssertEqual(Set(firstTasks.map(\.uid)).count, 3)
        XCTAssertEqual(AgentInbox.attentionTaskCount(firstTasks), 2)
        let firstAttention = AgentInbox.attention(firstTasks)
        XCTAssertEqual(
            Set(firstAttention.questions.map(\.uid)),
            Set(["codeheroes:decision:DL-INPUT", "codeheroes:decision:DL-ACTION"])
        )
        XCTAssertTrue(firstAttention.reviews.isEmpty)
        XCTAssertEqual(firstAttention.background.map(\.uid), ["codeheroes:decision:DL-EVIDENCE"])
        let evidence = try XCTUnwrap(firstTasks.first { $0.uid == "codeheroes:decision:DL-EVIDENCE" })
        XCTAssertEqual(evidence.stage, .needsReview)
        XCTAssertFalse(evidence.tags.contains("human-action"))
        let manualAction = try XCTUnwrap(firstTasks.first { $0.uid == "codeheroes:decision:DL-ACTION" })
        XCTAssertEqual(manualAction.stage, .needsInput)
        XCTAssertTrue(manualAction.tags.contains("human-action"))

        let second = await adapter.importQueue(at: fixture.queueURL)
        let secondTasks = try tasks(context)
        XCTAssertEqual(second.createdCount, 0)
        XCTAssertEqual(second.updatedCount, 0)
        XCTAssertEqual(second.unchangedCount, 3)
        XCTAssertEqual(secondTasks.count, 3)
        XCTAssertEqual(Set(secondTasks.map(\.uid)).count, 3)
        XCTAssertEqual(AgentInbox.attentionTaskCount(secondTasks), 2)
        let secondAttention = AgentInbox.attention(secondTasks)
        XCTAssertEqual(
            Set(secondAttention.questions.map(\.uid)),
            Set(["codeheroes:decision:DL-INPUT", "codeheroes:decision:DL-ACTION"])
        )
        XCTAssertTrue(secondAttention.reviews.isEmpty)
        XCTAssertEqual(secondAttention.background.map(\.uid), ["codeheroes:decision:DL-EVIDENCE"])
    }

    func test_sameQueuePreservesLocalResponseLifecycleUntilFreshQueueArrives() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)
        let task = try XCTUnwrap(try tasks(context).first)
        task.stage = .done
        task.tags.append("response:ignored")
        task.notes += "\nFeedback recorded: already-handled"
        try context.save()

        _ = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(task.stage, .done)
        XCTAssertTrue(task.tags.contains("response:ignored"))
        XCTAssertTrue(task.notes.contains("Feedback recorded: already-handled"))
    }

    func test_newerQueueMarksAbsentProjectionStaleWithoutTouchingOtherSources() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)
        let manual = MustardTask(title: "Personal")
        context.insert(manual)
        try context.save()

        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")])
        let report = await adapter.importQueue(at: fixture.queueURL)

        let stale = try XCTUnwrap(try tasks(context).first { $0.uid == "codeheroes:decision:DL-1" })
        XCTAssertEqual(stale.stage, .needsReview)
        XCTAssertTrue(stale.tags.contains("source-stale"))
        XCTAssertEqual(report.staleCount, 1)
        XCTAssertEqual(manual.title, "Personal")
    }

    func test_olderQueueDoesNotMarkExistingProjectionStale() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)

        try fixture.writeDecision("DEC-DL-2")
        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")], generatedAt: "2025-12-31T23:59:59Z")
        let report = await adapter.importQueue(at: fixture.queueURL)

        let existing = try XCTUnwrap(try tasks(context).first { $0.uid == "codeheroes:decision:DL-1" })
        XCTAssertFalse(existing.tags.contains("source-stale"))
        XCTAssertEqual(report.staleCount, 0)
        XCTAssertEqual(try tasks(context).first { $0.uid == "codeheroes:decision:DL-2" }?.title, "Decision")
    }

    func test_projectionWithoutValidPriorGeneratedAtDoesNotMarkStale() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let legacy = MustardTask(title: "Legacy projection", owner: .agent)
        legacy.uid = "codeheroes:decision:DL-1"
        legacy.source = CodeHeroesDecisionPolicy.source
        legacy.sourceURL = fixture.queueURL.standardizedFileURL.path
        legacy.sourceContext = "digest=old;run=RUN-OLD;cluster=DL-1;source_ids=DEC-DL-1"
        context.insert(legacy)
        try context.save()

        try fixture.writeDecision("DEC-DL-2")
        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")])
        let report = await CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow }).importQueue(at: fixture.queueURL)

        XCTAssertFalse(legacy.tags.contains("source-stale"))
        XCTAssertEqual(report.staleCount, 0)
    }

    func test_invalidGeneratedAtRejectsQueueWithoutMutationAndLaterNewerQueueCanStale() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)
        let original = try XCTUnwrap(try tasks(context).first { $0.uid == "codeheroes:decision:DL-1" })
        let originalContext = original.sourceContext
        let originalStage = original.stage

        try fixture.writeDecision("DEC-DL-2")
        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")], generatedAt: "not-a-date")
        let invalid = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(invalid.findings.count, 1)
        XCTAssertEqual(invalid.findings.first?.scope, .queue)
        XCTAssertEqual(invalid.findings.first?.reason, "Invalid generated_at timestamp")
        XCTAssertEqual(invalid.createdCount, 0)
        XCTAssertEqual(invalid.updatedCount, 0)
        XCTAssertEqual(invalid.staleCount, 0)
        XCTAssertEqual(try tasks(context).count, 1)
        XCTAssertEqual(original.sourceContext, originalContext)
        XCTAssertEqual(original.stage, originalStage)

        try fixture.writeQueue(clusters: [Fixture.cluster("DL-2")], generatedAt: "2026-01-02T00:00:00Z")
        let newer = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(newer.createdCount, 1)
        XCTAssertEqual(newer.staleCount, 1)
        XCTAssertTrue(original.tags.contains("source-stale"))
    }

    func test_queueAtDifferentPathDoesNotMarkOtherQueueProjectionStale() async throws {
        let first = try Fixture()
        let second = try Fixture(clusters: [Fixture.cluster("DL-2")])
        let context = try makeContext()
        _ = await CodeHeroesDecisionAdapter(context: context, repositoryRoot: first.root, now: { self.fixedNow }).importQueue(at: first.queueURL)

        let report = await CodeHeroesDecisionAdapter(context: context, repositoryRoot: second.root, now: { self.fixedNow }).importQueue(at: second.queueURL)

        let firstTask = try XCTUnwrap(try tasks(context).first { $0.uid == "codeheroes:decision:DL-1" })
        XCTAssertEqual(firstTask.sourceURL, first.queueURL.standardizedFileURL.path)
        XCTAssertFalse(firstTask.tags.contains("source-stale"))
        XCTAssertEqual(report.staleCount, 0)
    }

    func test_foreignUIDCollisionIsReportedWithoutChangingForeignTask() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let foreign = MustardTask(title: "Do not touch")
        foreign.uid = "codeheroes:decision:DL-1"
        context.insert(foreign)
        try context.save()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.collisionCount, 1)
        XCTAssertEqual(foreign.title, "Do not touch")
        XCTAssertEqual(foreign.source, "manual")
    }

    func test_escapedSymlinkDecisionSourceSkipsClusterWithoutMutatingTasks() async throws {
        let fixture = try Fixture()
        let escaped = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "# DEC-DL-1".write(to: escaped, atomically: true, encoding: .utf8)
        let local = fixture.root.appendingPathComponent("operations/decisions/open/DEC-DL-1.md")
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: escaped)
        defer { try? FileManager.default.removeItem(at: escaped) }
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.reason, "Missing or escaped decision source")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_escapedDecisionSourceDirectorySymlinkSkipsClusterWithoutExternalLink() async throws {
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

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.findings.first?.reason, "Missing or escaped decision source")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_injectedFileManagerReadFailureIsReportedWithoutModelMutation() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, fileManager: FailingReadFileManager(), now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.findings.first?.reason, "Unable to read queue file")
        XCTAssertEqual(try tasks(context).count, 0)
    }

    func test_saveFailureRestoresExistingProjectionAndDoesNotLeakChangesIntoLaterSave() async throws {
        let fixture = try Fixture(clusters: [Fixture.cluster("DL-1", title: "Updated")])
        let context = try makeContext()
        let existing = MustardTask(title: "Original", owner: .agent)
        existing.uid = "codeheroes:decision:DL-1"
        existing.source = CodeHeroesDecisionPolicy.source
        existing.sourceContext = "digest=old;run=RUN-OLD;cluster=DL-1;source_ids=DEC-DL-1"
        existing.stage = .needsReview
        context.insert(existing)
        try context.save()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow }, saveContext: { throw SaveFailure.forced })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.staleCount, 0)
        XCTAssertEqual(existing.title, "Original")
        XCTAssertEqual(existing.stage, .needsReview)
        let unrelated = MustardTask(title: "Unrelated")
        context.insert(unrelated)
        try context.save()
        XCTAssertEqual(try XCTUnwrap(try tasks(context).first { $0.uid == existing.uid }).title, "Original")
    }

    func test_saveFailureCleansUpBrandNewProjectionAndItsAreaAndList() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow }, saveContext: { throw SaveFailure.forced })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.createdCount, 0)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.staleCount, 0)
        XCTAssertEqual(try tasks(context).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Area>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskList>()).count, 0)
    }

    func test_duplicateExistingProjectionUIDSkipsClusterWithoutChangingEitherTask() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let first = MustardTask(title: "First", owner: .agent)
        let second = MustardTask(title: "Second", owner: .agent)
        for task in [first, second] {
            task.uid = "codeheroes:decision:DL-1"
            task.source = CodeHeroesDecisionPolicy.source
            task.sourceContext = "digest=old;run=RUN-OLD;cluster=DL-1;source_ids=DEC-DL-1"
            context.insert(task)
        }
        try context.save()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.collisionCount, 1)
        XCTAssertEqual(first.title, "First")
        XCTAssertEqual(second.title, "Second")
    }

    func test_invalidSourceClusterDoesNotMarkExistingProjectionStale() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("operations/decisions/open/DEC-DL-1.md"))

        let report = await adapter.importQueue(at: fixture.queueURL)

        let existing = try XCTUnwrap(try tasks(context).first)
        XCTAssertEqual(report.staleCount, 0)
        XCTAssertFalse(existing.tags.contains("source-stale"))
    }

    func test_sameQueueBytesRefreshesDecisionLinkWhenSourceMovesToResolved() async throws {
        let fixture = try Fixture()
        let context = try makeContext()
        let adapter = CodeHeroesDecisionAdapter(context: context, repositoryRoot: fixture.root, now: { self.fixedNow })
        _ = await adapter.importQueue(at: fixture.queueURL)
        let task = try XCTUnwrap(try tasks(context).first)
        let oldLink = try XCTUnwrap(task.links.last?.url)
        try fixture.moveDecisionToResolved("DEC-DL-1")

        let report = await adapter.importQueue(at: fixture.queueURL)

        XCTAssertEqual(report.updatedCount, 1)
        XCTAssertNotEqual(task.links.last?.url, oldLink)
        XCTAssertTrue(task.links.last?.url.contains("/resolved/DEC-DL-1.md") == true)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: Area.self, TaskList.self, MustardTask.self, Recommendation.self, AgentRun.self, AgentMessage.self, CalendarEvent.self, configurations: configuration))
    }

    private func tasks(_ context: ModelContext) throws -> [MustardTask] { try context.fetch(FetchDescriptor<MustardTask>()) }
}

private enum SaveFailure: Error { case forced }

private final class FailingReadFileManager: FileManager {
    override func contents(atPath path: String) -> Data? { nil }
}

private final class MetadataThreadRecordingFileManager: FileManager {
    private let lock = NSLock()
    private var metadataThreads: [Bool] = []

    var metadataCallCount: Int { lock.withLock { metadataThreads.count } }
    var didReadMetadataOnMainThread: Bool { lock.withLock { metadataThreads.contains(true) } }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.withLock { metadataThreads.append(Thread.isMainThread) }
        return try super.attributesOfItem(atPath: path)
    }
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

    static func cluster(
        _ id: String,
        project: String = "dl",
        title: String = "Decision",
        triageState: String = "needs-human-decision",
        stage: String = "needsInput",
        decisionRequired: Bool = true,
        humanActionRequired: Bool = true
    ) -> CodeHeroesDecisionQueue.Cluster {
        .init(
            clusterID: id, projectID: project, title: title, triageState: triageState,
            mustardStage: stage, priority: "high", decisionRequired: decisionRequired,
            humanActionRequired: humanActionRequired, question: "Question", nextAction: "Next",
            whyGrouped: "Why", sourceDecisionIDs: ["DEC-\(id)"]
        )
    }

    func writeQueue(clusters: [CodeHeroesDecisionQueue.Cluster], generatedAt: String = "2026-01-01T00:00:00Z") throws {
        let document = CodeHeroesDecisionQueue.Document(schemaVersion: 1, reportType: "dream_decision_triage", generatedAt: generatedAt, sourceRunID: "RUN-1", sourceReceipt: receipt, canonicalInput: "operations/input.md", readOnly: true, decisionStatusMutations: 0, mustardImport: "future-adapter-only", summary: [:], historicalOpenDecisionIDs: [], historicalExclusions: [], queue: clusters)
        try JSONEncoder().encode(document).write(to: queueURL)
    }

    func moveDecisionToResolved(_ id: String) throws {
        let open = root.appendingPathComponent("operations/decisions/open/\(id).md")
        let resolvedDirectory = root.appendingPathComponent("operations/decisions/resolved")
        try FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: open, to: resolvedDirectory.appendingPathComponent("\(id).md"))
    }

    func writeDecision(_ id: String) throws {
        try "# \(id)".write(to: root.appendingPathComponent("operations/decisions/open/\(id).md"), atomically: true, encoding: .utf8)
    }
}
