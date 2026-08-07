import XCTest
import SwiftData
@testable import MustardKit

/// BAK-246 — the scheduled-placement invariant: a task with `scheduledAt != nil`
/// is never in `.inbox`. It belongs in `.scheduled` when `isTimed`, `.planned`
/// otherwise. Pure helper + a one-time store migration for already-stranded rows.
final class PersonalBoardPlacementTests: XCTestCase {

    // MARK: normalizePlacement (pure)

    func test_scheduledUntimedInbox_becomesPlanned() {
        let t = MustardTask(title: "x", scheduledAt: Date(timeIntervalSince1970: 1))
        t.stage = .inbox
        t.isTimed = false
        PersonalBoard.normalizePlacement(t)
        XCTAssertEqual(t.stage, .planned)
    }

    func test_scheduledTimedInbox_becomesScheduled() {
        let t = MustardTask(title: "x", scheduledAt: Date(timeIntervalSince1970: 1))
        t.stage = .inbox
        t.isTimed = true
        PersonalBoard.normalizePlacement(t)
        XCTAssertEqual(t.stage, .scheduled)
    }

    func test_unscheduledInbox_staysInbox() {
        let t = MustardTask(title: "x")   // scheduledAt nil
        t.stage = .inbox
        PersonalBoard.normalizePlacement(t)
        XCTAssertEqual(t.stage, .inbox, "untriaged, unscheduled tasks belong in Inbox")
    }

    func test_scheduledNonInbox_stageUntouched() {
        // Past the inbox — agent lanes, in-progress, done — keep their stage even
        // when scheduled; the invariant only rescues from Inbox.
        for stage in [TaskStage.needsApproval, .queued, .inProgress, .done, .planned, .scheduled] {
            let t = MustardTask(title: "x", scheduledAt: Date(timeIntervalSince1970: 1))
            t.stage = stage
            t.isTimed = true
            PersonalBoard.normalizePlacement(t)
            XCTAssertEqual(t.stage, stage, "\(stage) must be left alone")
        }
    }

    func test_idempotent() {
        let t = MustardTask(title: "x", scheduledAt: Date(timeIntervalSince1970: 1))
        t.stage = .inbox
        PersonalBoard.normalizePlacement(t)
        let once = t.stage
        PersonalBoard.normalizePlacement(t)
        XCTAssertEqual(t.stage, once)
    }

    // MARK: normalizeScheduledPlacement (store migration)

    func test_migration_repairsStrandedInboxCards() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        let ctx = ModelContext(container)

        let strandedUntimed = MustardTask(title: "planned", scheduledAt: Date(timeIntervalSince1970: 1))
        strandedUntimed.stage = .inbox; strandedUntimed.isTimed = false

        let strandedTimed = MustardTask(title: "timed", scheduledAt: Date(timeIntervalSince1970: 1))
        strandedTimed.stage = .inbox; strandedTimed.isTimed = true

        let untriaged = MustardTask(title: "untriaged")           // no schedule → stays
        untriaged.stage = .inbox

        let doneScheduled = MustardTask(title: "done", scheduledAt: Date(timeIntervalSince1970: 1))
        doneScheduled.stage = .done                               // not inbox → untouched

        [strandedUntimed, strandedTimed, untriaged, doneScheduled].forEach(ctx.insert)

        BoardMigration.normalizeScheduledPlacement(ctx)

        XCTAssertEqual(strandedUntimed.stage, .planned)
        XCTAssertEqual(strandedTimed.stage, .scheduled)
        XCTAssertEqual(untriaged.stage, .inbox)
        XCTAssertEqual(doneScheduled.stage, .done)
    }
}
