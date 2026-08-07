import XCTest
import SwiftData
@testable import MustardKit

final class BoardMigrationTests: XCTestCase {
    func test_meTask_mapsByStatus() {
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .inbox, scheduledAt: nil, owner: .me), .inbox)
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .inProgress, scheduledAt: nil, owner: .me), .inProgress)
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .done, scheduledAt: nil, owner: .me), .done)
    }

    func test_someday_collapsesToInbox() {
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .someday, scheduledAt: nil, owner: .me), .inbox)
    }

    func test_plannedWithDate_becomesScheduled() {
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .planned, scheduledAt: Date(timeIntervalSince1970: 1), owner: .me), .scheduled)
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .planned, scheduledAt: nil, owner: .me), .planned)
    }

    func test_agentTask_landsInQueued() {
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .inProgress, scheduledAt: nil, owner: .agent), .queued)
        XCTAssertEqual(BoardMigration.stage(legacyStatus: .done, scheduledAt: nil, owner: .agent), .done)
    }

    /// Launch-path behaviour: backfill migrates an un-migrated task once, then is a
    /// no-op on re-run (the `migratedStage` guard), so it never clobbers later edits.
    func test_backfill_migratesOnce_thenIdempotent() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        let ctx = ModelContext(container)
        let t = MustardTask(title: "legacy")
        t.statusRaw = TaskStatus.someday.rawValue
        t.migratedStage = false
        ctx.insert(t)

        BoardMigration.backfill(ctx)
        XCTAssertEqual(t.stage, .inbox)        // someday → inbox
        XCTAssertTrue(t.migratedStage)

        // A later manual change must survive a second backfill (idempotent).
        t.stage = .queued
        BoardMigration.backfill(ctx)
        XCTAssertEqual(t.stage, .queued)
    }

    /// Regression: a task created in-app (born `migratedStage = true`) and placed at a
    /// non-inbox stage must NOT be reverted to inbox by the launch backfill, which
    /// derives stage from the (stale, default-inbox) legacy `statusRaw`.
    func test_backfill_doesNotClobberNewlyCreatedTaskStage() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        let ctx = ModelContext(container)
        let t = MustardTask(title: "added via +Add")  // born migratedStage = true
        t.stage = .inProgress                          // statusRaw stays default "inbox"
        ctx.insert(t)

        BoardMigration.backfill(ctx)
        XCTAssertEqual(t.stage, .inProgress, "backfill must not revert an in-app task's stage")
    }
}
