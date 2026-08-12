import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class CodeHeroesQueueSettingsTests: XCTestCase {
    func test_settingsRoundTripPreservesValuesInInjectedDefaults() {
        let defaults = makeDefaults()
        let settings = CodeHeroesQueueSettings(
            repositoryRoot: "/tmp/code-heroes",
            queuePath: "/tmp/code-heroes/operations/decision-queue.json",
            enabled: true
        )

        CodeHeroesQueueSettingsStore.save(settings, to: defaults)

        XCTAssertEqual(CodeHeroesQueueSettingsStore.load(from: defaults), settings)
    }

    func test_settingsLoadFallsBackToDisabledDefaultsForMissingOrMalformedData() {
        let defaults = makeDefaults()

        XCTAssertEqual(CodeHeroesQueueSettingsStore.load(from: defaults), .init())

        defaults.set(Data("not json".utf8), forKey: CodeHeroesQueueSettingsStore.key)
        XCTAssertEqual(CodeHeroesQueueSettingsStore.load(from: defaults), .init())
    }

    func test_resetClearsPersistedSettingsBackToDefaults() {
        let defaults = makeDefaults()
        CodeHeroesQueueSettingsStore.save(.init(repositoryRoot: "/repo", queuePath: "/repo/queue.json", enabled: true), to: defaults)

        CodeHeroesQueueSettingsStore.reset(defaults)

        XCTAssertEqual(CodeHeroesQueueSettingsStore.load(from: defaults), .init())
    }

    func test_manualImportRejectsEmptyPathsAndExposesCodeHeroesSpecificError() throws {
        let service = AgentService(context: try makeContext())

        let report = service.importCodeHeroesDecisionQueue(settings: .init(enabled: true))

        XCTAssertNil(report)
        XCTAssertFalse(service.isImportingCodeHeroesQueue)
        XCTAssertNil(service.lastCodeHeroesImportSummary)
        XCTAssertEqual(service.lastCodeHeroesImportError, "Code Heroes import requires a repository root and queue file path.")
        XCTAssertNil(service.lastError)
    }

    func test_manualImportRejectsMissingOrNonFileQueueWithoutChangingGeneralError() throws {
        let fixture = try QueueFixture()
        let service = AgentService(context: try makeContext())
        let settings = CodeHeroesQueueSettings(repositoryRoot: fixture.root.path, queuePath: fixture.root.appendingPathComponent("missing.json").path, enabled: true)

        XCTAssertNil(service.importCodeHeroesDecisionQueue(settings: settings))
        XCTAssertFalse(service.isImportingCodeHeroesQueue)
        XCTAssertEqual(service.lastCodeHeroesImportError, "Code Heroes import queue file is unavailable.")
        XCTAssertNil(service.lastError)
    }

    func test_manualImportReturnsMalformedQueueReportWithSafeCodeHeroesError() throws {
        let fixture = try QueueFixture()
        try Data("not queue json".utf8).write(to: fixture.queueURL)
        let service = AgentService(context: try makeContext())
        let settings = CodeHeroesQueueSettings(repositoryRoot: fixture.root.path, queuePath: fixture.queueURL.path, enabled: true)

        let report = service.importCodeHeroesDecisionQueue(settings: settings)

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.createdCount, 0)
        XCTAssertEqual(service.lastCodeHeroesImportSummary, report?.summary)
        XCTAssertEqual(service.lastCodeHeroesImportError, "Code Heroes import: Queue JSON could not be decoded")
        XCTAssertFalse(service.isImportingCodeHeroesQueue)
        XCTAssertNil(service.lastError)
    }

    func test_manualImportCreatesProjectionAndReportsCodeHeroesSpecificStatus() throws {
        let fixture = try QueueFixture()
        let context = try makeContext()
        let service = AgentService(context: context)
        let settings = CodeHeroesQueueSettings(repositoryRoot: fixture.root.path, queuePath: fixture.queueURL.path, enabled: true)

        let report = service.importCodeHeroesDecisionQueue(settings: settings, now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(report?.createdCount, 1)
        XCTAssertEqual(report?.repositoryWrites, 0)
        XCTAssertEqual(report?.externalWrites, 0)
        XCTAssertEqual(service.lastCodeHeroesImportSummary, report?.summary)
        XCTAssertNil(service.lastCodeHeroesImportError)
        XCTAssertFalse(service.isImportingCodeHeroesQueue)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).count, 1)
    }

    func test_manualImportRemainsAvailableWhenAutomaticRefreshPreferenceIsDisabled() throws {
        let fixture = try QueueFixture()
        let context = try makeContext()
        let service = AgentService(context: context, claude: { _, _ in
            XCTFail("Manual Code Heroes import must not invoke the agent or a scheduler")
            return ClaudeResult(ok: false, text: "unexpected")
        })
        let settings = CodeHeroesQueueSettings(repositoryRoot: fixture.root.path, queuePath: fixture.queueURL.path, enabled: false)

        let report = service.importCodeHeroesDecisionQueue(settings: settings)

        XCTAssertEqual(report?.createdCount, 1)
        XCTAssertNil(service.lastCodeHeroesImportError)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MustardTask>()).count, 1)
    }

    func test_manualRefreshPresentationRequiresBothPathsAndAnIdleImport() {
        let readyButDisabled = CodeHeroesQueueSettings(
            repositoryRoot: " /repo ",
            queuePath: " /repo/operations/decision-queue.json ",
            enabled: false
        )

        XCTAssertTrue(CodeHeroesQueueRefreshPresentation.canRefresh(
            settings: readyButDisabled,
            isImporting: false
        ))
        XCTAssertFalse(CodeHeroesQueueRefreshPresentation.canRefresh(
            settings: readyButDisabled,
            isImporting: true
        ))
        XCTAssertFalse(CodeHeroesQueueRefreshPresentation.canRefresh(
            settings: .init(repositoryRoot: "/repo"),
            isImporting: false
        ))
        XCTAssertFalse(CodeHeroesQueueRefreshPresentation.canRefresh(
            settings: .init(queuePath: "/repo/queue.json"),
            isImporting: false
        ))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "CodeHeroesQueueSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

private final class QueueFixture {
    let root: URL
    let queueURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        queueURL = root.appendingPathComponent("operations/decision-queue.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("operations/decisions/open"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("operations/receipts"), withIntermediateDirectories: true)
        try "receipt".write(to: root.appendingPathComponent("operations/receipts/RUN-1.md"), atomically: true, encoding: .utf8)
        try "# DEC-DL-1".write(to: root.appendingPathComponent("operations/decisions/open/DEC-DL-1.md"), atomically: true, encoding: .utf8)

        let cluster = CodeHeroesDecisionQueue.Cluster(
            clusterID: "DL-1", projectID: "dl", title: "Decision", triageState: "needs-human-decision",
            mustardStage: "needsInput", priority: "high", decisionRequired: true, humanActionRequired: true,
            question: "Question", nextAction: "Next", whyGrouped: "Why", sourceDecisionIDs: ["DEC-DL-1"]
        )
        let document = CodeHeroesDecisionQueue.Document(
            schemaVersion: 1, reportType: "dream_decision_triage", generatedAt: "2026-01-01T00:00:00Z",
            sourceRunID: "RUN-1", sourceReceipt: "operations/receipts/RUN-1.md", canonicalInput: "operations/input.md",
            readOnly: true, decisionStatusMutations: 0, mustardImport: "future-adapter-only", summary: [:],
            historicalOpenDecisionIDs: [], historicalExclusions: [], queue: [cluster]
        )
        try JSONEncoder().encode(document).write(to: queueURL)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
