import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class SourcePipelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        return ModelContext(container)
    }

    // Task 8 — manual sweep now flows through the shared pipeline, so it dedupes.
    func test_manualSweep_twiceSameOutput_doesNotDuplicate() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: true, text: #"[{"title":"One"},{"title":"Two"}]"#) }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/v")
        await service.sweep(vaultPath: "/v")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 2,
                       "re-running the vault sweep with identical output must not duplicate cards")
    }

    func test_manualSweep_stampsSourceIdentity() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: true, text: #"[{"title":"One"}]"#) }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/v")
        let rec = try ctx.fetch(FetchDescriptor<Recommendation>()).first
        XCTAssertEqual(rec?.source, "vault")
        XCTAssertNotNil(rec?.sourceEventID)
        XCTAssertEqual(rec?.vaultPath, "/v")
    }

    // Task 7 — per-source scheduled sweep.
    func test_sweepDueSources_dueVault_ingestsAndAdvancesState() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: #"[{"title":"One"}]"#) })
        let settings = SourceSettings(
            sources: [SourceConfig(id: .vault, enabled: true, intervalHours: 4, workingDirectory: "/v")],
            state: [SourceState(id: .vault, lastSweptAt: nil)]
        )
        let updated = await service.sweepDueSources(settings, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 1)
        XCTAssertEqual(updated.state.first { $0.id == .vault }?.lastSweptAt, now)
        XCTAssertNil(updated.state.first { $0.id == .vault }?.lastError)
    }

    func test_sweepDueSources_notDue_skips() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "[]") })
        let settings = SourceSettings(
            sources: [SourceConfig(id: .vault, enabled: true, intervalHours: 4, workingDirectory: "/v")],
            state: [SourceState(id: .vault, lastSweptAt: now.addingTimeInterval(-3600))]  // 1h ago < 4h
        )
        _ = await service.sweepDueSources(settings, now: now)
        XCTAssertFalse(called)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }

    func test_sweepDueSources_failedRun_setsError_doesNotAdvance() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: false, text: "401") })
        let settings = SourceSettings(
            sources: [SourceConfig(id: .vault, enabled: true, intervalHours: 4, workingDirectory: "/v")],
            state: [SourceState(id: .vault, lastSweptAt: nil)]
        )
        let updated = await service.sweepDueSources(settings, now: now)
        let st = updated.state.first { $0.id == .vault }
        XCTAssertNil(st?.lastSweptAt, "failed run must not advance scheduling state")
        XCTAssertEqual(st?.lastError, "401")
    }

    func test_sweepDueSources_unparseableOutput_setsError_doesNotAdvance() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "not json at all") })
        let settings = SourceSettings(
            sources: [SourceConfig(id: .vault, enabled: true, intervalHours: 4, workingDirectory: "/v")],
            state: [SourceState(id: .vault, lastSweptAt: nil)]
        )
        let updated = await service.sweepDueSources(settings, now: now)
        let st = updated.state.first { $0.id == .vault }
        XCTAssertNil(st?.lastSweptAt, "unparseable output must not advance scheduling state")
        XCTAssertEqual(st?.lastError, "Sweep returned output Mustard couldn't parse")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }

    func test_sweepDueSources_disabled_skips() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "[]") })
        let settings = SourceSettings(
            sources: [SourceConfig(id: .vault, enabled: false, intervalHours: 4, workingDirectory: "/v")],
            state: []
        )
        _ = await service.sweepDueSources(settings, now: now)
        XCTAssertFalse(called)
    }

    // Multi-project isolation, end to end.
    func test_sweep_stampsProjectFromVaultPath() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: #"[{"title":"One"}]"#) })
        await service.sweep(vaultPath: "/Users/x/DL-Knowledge-Base")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).first?.project, "DL-Knowledge-Base")
    }

    func test_twoProjects_identicalContent_doNotCrossContaminate() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: true, text: #"[{"title":"Weekly status"}]"#) }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/Users/x/DL-Knowledge-Base")
        await service.sweep(vaultPath: "/Users/x/Sandvik-Knowledge-Base")
        let recs = try ctx.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2, "identical content in two KBs must NOT dedupe-collapse across projects")
        XCTAssertEqual(Set(recs.map(\.project)).count, 2)
    }

    func test_sweepDueSources_multipleVaultProjects_isolatedAndPerProjectState() async throws {
        let ctx = try makeContext()
        var seenCwds: [String] = []
        let stub: ClaudeRun = { _, cwd in seenCwds.append(cwd); return ClaudeResult(ok: true, text: #"[{"title":"Status"}]"#) }
        let service = AgentService(context: ctx, claude: stub)
        let settings = SourceSettings(
            sources: [
                SourceConfig(id: .vault, project: "DL", enabled: true, intervalHours: 4, workingDirectory: "/kb/DL"),
                SourceConfig(id: .vault, project: "Sandvik", enabled: true, intervalHours: 4, workingDirectory: "/kb/Sandvik"),
            ],
            state: []
        )
        let updated = await service.sweepDueSources(settings, now: now)
        let recs = try ctx.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(Set(recs.map(\.project)), ["DL", "Sandvik"])
        XCTAssertEqual(Set(recs.map(\.vaultPath)), ["/kb/DL", "/kb/Sandvik"])
        XCTAssertEqual(Set(seenCwds), ["/kb/DL", "/kb/Sandvik"], "each project sweeps in its own cwd")
        XCTAssertEqual(updated.state.filter { $0.lastSweptAt == now }.count, 2, "per-project scheduling state advanced")
    }
}
