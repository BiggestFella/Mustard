import XCTest
@testable import MustardKit

final class BridgeExportTests: XCTestCase {
    private func task(
        _ stage: TaskStage,
        uid: String,
        action: RecommendationAction? = nil,
        connected: Bool = false
    ) -> MustardTask {
        let t = MustardTask(title: "t-\(uid)"); t.uid = uid; t.stage = stage
        if let action { t.actionType = action }
        if connected {
            let run = AgentRun(task: t)
            run.requiresConnectedWorker = true
            t.agentRun = run
        }
        return t
    }
    private let target = BridgeExport.RouteTarget(workingDir: "/kb/DL", project: "DL")
    private func route(_ t: MustardTask) -> BridgeExport.RouteTarget? { target }
    private let now = Date(timeIntervalSince1970: 1)

    func test_connectedQueuedTask_withoutOutbox_writesExecuteOrder() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", action: .ticket, connected: true)],
                                     route: route, liveOutboxUIDs: [:], now: now)
        XCTAssertEqual(plan.writes.count, 1)
        XCTAssertEqual(plan.writes[0].workingDir, "/kb/DL")
        XCTAssertEqual(plan.writes[0].order.uid, "u1")
        XCTAssertEqual(plan.writes[0].order.mode, "execute")
        XCTAssertEqual(plan.writes[0].order.actionType, "ticket_write")
        XCTAssertTrue(plan.cancels.isEmpty)
    }

    func test_connectedForAgentTask_writesPrepOrder() {
        let plan = BridgeExport.plan(tasks: [task(.forAgent, uid: "u2", connected: true)],
                                     route: route, liveOutboxUIDs: [:], now: now)
        XCTAssertEqual(plan.writes.first?.order.mode, "prep")
    }

    func test_taskWithLiveOutbox_isSkipped() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", connected: true)],
                                     route: route, liveOutboxUIDs: ["/kb/DL": ["u1"]], now: now)
        XCTAssertTrue(plan.writes.isEmpty)
    }

    // BAK-92: the worker archives the outbox file + writes a result before Mustard's
    // next ingest tick. In that window the task is still `.queued` with no live outbox
    // file — without a result guard the export re-issues a duplicate order (double-run).
    func test_queuedTask_withLiveResult_isSkipped() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", connected: true)],
                                     route: route, liveOutboxUIDs: [:],
                                     liveResultUIDs: ["/kb/DL": ["u1"]], now: now)
        XCTAssertTrue(plan.writes.isEmpty, "a live result for the uid must suppress re-issue")
    }

    // A live result for a DIFFERENT uid must not suppress an unrelated task's order.
    func test_liveResultForOtherUID_doesNotSuppress() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", action: .ticket, connected: true)],
                                     route: route, liveOutboxUIDs: [:],
                                     liveResultUIDs: ["/kb/DL": ["u9"]], now: now)
        XCTAssertEqual(plan.writes.map(\.order.uid), ["u1"])
    }

    // A result in another working dir must not suppress this dir's order.
    func test_liveResultInOtherDir_doesNotSuppress() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", action: .ticket, connected: true)],
                                     route: route, liveOutboxUIDs: [:],
                                     liveResultUIDs: ["/kb/OTHER": ["u1"]], now: now)
        XCTAssertEqual(plan.writes.map(\.order.uid), ["u1"])
    }

    // Retry contract (BAK-92): the guard keys on LIVE results only. A `failed` result
    // is archived to `results/done/` (so it leaves `liveResultUIDs`) while the task
    // stays at its source stage — the next export MUST re-issue it. Asserting that an
    // empty live-result set still writes locks this in against a "check done/ too"
    // regression that would permanently strand retried/re-queued uids.
    func test_queuedTask_withNoLiveResult_reissues() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1", action: .ticket, connected: true)],
                                     route: route, liveOutboxUIDs: [:],
                                     liveResultUIDs: ["/kb/DL": []], now: now)
        XCTAssertEqual(plan.writes.map(\.order.uid), ["u1"], "no live result → must re-issue (retry)")
    }

    // The uid-keyed guard is mode-independent: a forAgent (prep) task is suppressed
    // by a live result just as an execute task is.
    func test_forAgentTask_withLiveResult_isSkipped() {
        let plan = BridgeExport.plan(tasks: [task(.forAgent, uid: "u2", connected: true)],
                                     route: route, liveOutboxUIDs: [:],
                                     liveResultUIDs: ["/kb/DL": ["u2"]], now: now)
        XCTAssertTrue(plan.writes.isEmpty)
    }

    // BAK-89: a queued task with no actionType would export an `execute` order with
    // actionType="" — the worker can't act on it. The export must skip it (the UI
    // surfaces "needs an action type"); a queued task means the action is known.
    func test_queuedTask_withoutActionType_isSkipped() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1")],   // no action
                                     route: route, liveOutboxUIDs: [:], now: now)
        XCTAssertTrue(plan.writes.isEmpty, "must not emit an execute order with empty actionType")
    }

    // forAgent/prep legitimately has no actionType yet — that's exactly what the prep
    // pass classifies — so it must still be exported.
    func test_forAgentTask_withoutActionType_stillWritesPrep() {
        let plan = BridgeExport.plan(tasks: [task(.forAgent, uid: "u2", connected: true)],  // no action
                                     route: route, liveOutboxUIDs: [:], now: now)
        XCTAssertEqual(plan.writes.first?.order.mode, "prep")
        XCTAssertEqual(plan.writes.first?.order.actionType, "")
    }

    // The no-action skip must not disturb BAK-92's cancel logic: a queued no-action
    // task with a LIVE outbox stays in the active set (insert precedes the guard), so
    // its outbox is neither re-issued nor spuriously cancelled. Guards the load-bearing
    // insert-before-guard ordering against a future refactor.
    func test_queuedNoAction_withLiveOutbox_neitherWritesNorCancels() {
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1")],   // no action
                                     route: route, liveOutboxUIDs: ["/kb/DL": ["u1"]], now: now)
        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertTrue(plan.cancels.isEmpty)
    }

    func test_localAgentTask_withoutConnectedFallback_neverWritesNewOrder() {
        let tasks = [
            task(.forAgent, uid: "prep"),
            task(.queued, uid: "execute", action: .ticket)
        ]

        let plan = BridgeExport.plan(tasks: tasks, route: route, liveOutboxUIDs: [:], now: now)

        XCTAssertTrue(plan.writes.isEmpty)
    }

    func test_localAgentTask_withHistoricalLiveOrder_remainsActiveWithoutNewWrite() {
        let local = task(.queued, uid: "u1", action: .ticket)

        let plan = BridgeExport.plan(
            tasks: [local], route: route,
            liveOutboxUIDs: ["/kb/DL": ["u1"]], now: now
        )

        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertTrue(plan.cancels.isEmpty)
    }

    func test_nonAgentStage_isIgnored() {
        let plan = BridgeExport.plan(tasks: [task(.planned, uid: "u3")],
                                     route: route, liveOutboxUIDs: [:], now: now)
        XCTAssertTrue(plan.writes.isEmpty)
    }

    func test_staleOutbox_isCancelled() {
        // live outbox u9, but no forAgent/queued task for it → cancel
        let plan = BridgeExport.plan(tasks: [task(.queued, uid: "u1")],
                                     route: route, liveOutboxUIDs: ["/kb/DL": ["u1", "u9"]], now: now)
        XCTAssertEqual(plan.cancels, [BridgeExport.Cancel(workingDir: "/kb/DL", uid: "u9")])
    }
}
