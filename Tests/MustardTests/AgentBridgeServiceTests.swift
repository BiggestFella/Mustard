import XCTest
import SwiftData
@testable import MustardKit

final class AgentBridgeServiceTests: XCTestCase {
    final class StubIO: BridgeIO {
        var written: [AgentWorkOrder] = []
        var cancelled: [String] = []
        var archived: [String] = []
        var live: Set<String> = []
        var liveResults: Set<String> = []
        var results: [(AgentResult, String)] = []
        var quarantineCalls = 0
        func liveOutboxUIDs(workingDir: String) -> Set<String> { live }
        func liveResultUIDs(workingDir: String) -> Set<String> { liveResults }
        func writeWorkOrder(_ order: AgentWorkOrder, workingDir: String) throws { written.append(order) }
        func cancelWorkOrder(uid: String, workingDir: String) throws { cancelled.append(uid) }
        func readResults(workingDir: String) -> [(result: AgentResult, path: String)] { results.map { ($0.0, $0.1) } }
        func archiveResult(_ path: String, workingDir: String) throws { archived.append(path) }
        func quarantineUndecodableResults(workingDir: String) -> Int { quarantineCalls += 1; return 0 }
    }

    @MainActor
    private func service(_ io: StubIO) throws -> (AgentService, ModelContext) {
        let c = try ModelContainer(for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
                                   AgentRun.self, AgentMessage.self, AgentDraft.self, CalendarEvent.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        return (AgentService(context: ctx, claude: { _, _ in .init(ok: true, text: "") }, bridge: io), ctx)
    }

    @MainActor
    func test_export_skipsOrdinaryQueuedLocalTask() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        // Route the task to the DL area so exportWorkOrders' area filter selects it.
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "DL", area: area)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued; t.actionType = .ticket
        t.list = list
        ctx.insert(area); ctx.insert(list); ctx.insert(t)
        svc.exportWorkOrders(workingDir: "/kb/DL", area: "Digital Licence", project: "DL")
        XCTAssertTrue(io.written.isEmpty)
    }

    @MainActor
    func test_export_writesConnectedFallbackTask() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "DL", area: area)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued; t.actionType = .ticket
        t.list = list
        let run = AgentRun(task: t)
        run.requiresConnectedWorker = true
        t.agentRun = run
        ctx.insert(area); ctx.insert(list); ctx.insert(t); ctx.insert(run)

        svc.exportWorkOrders(workingDir: "/kb/DL", area: "Digital Licence", project: "DL")

        XCTAssertEqual(io.written.map(\.uid), ["u1"])
        XCTAssertEqual(io.written.first?.mode, "execute")
    }

    // MARK: - F26: area-less hand-offs export to the default KB

    @MainActor
    func test_exportAreaLessWork_writesAreaLessConnectedTask() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        // A voice hand-off with NO area (BAK-90 strander) + connected-worker flag.
        let t = MustardTask(title: "Email Bree"); t.uid = "v1"; t.stage = .queued; t.actionType = .draftEmail
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; t.agentRun = run
        ctx.insert(t); ctx.insert(run)

        svc.exportAreaLessWork(workingDir: "/kb/ch-work", project: "Code Heroes")

        XCTAssertEqual(io.written.map(\.uid), ["v1"])
        XCTAssertEqual(io.written.first?.mode, "execute")
        XCTAssertEqual(io.written.first?.actionType, "draft_email")
    }

    @MainActor
    func test_exportAreaLessWork_ignoresAreadTasks() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        // A task WITH an area belongs to its KB's export, not the default sweep.
        let area = Area(name: "Digital Licence"); let list = TaskList(name: "DL", area: area)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued; t.actionType = .ticket
        t.list = list
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; t.agentRun = run
        ctx.insert(area); ctx.insert(list); ctx.insert(t); ctx.insert(run)

        svc.exportAreaLessWork(workingDir: "/kb/ch-work", project: "Code Heroes")

        XCTAssertTrue(io.written.isEmpty, "area'd tasks route through their own KB, not the default")
    }

    @MainActor
    func test_exportAreaLessWork_skipsOrdinaryLocalAreaLessTask() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        // No connected-worker flag → the local coordinator owns it; never exported.
        let t = MustardTask(title: "jot"); t.uid = "u1"; t.stage = .queued; t.actionType = .draftEmail
        ctx.insert(t)

        svc.exportAreaLessWork(workingDir: "/kb/ch-work", project: "Code Heroes")

        XCTAssertTrue(io.written.isEmpty)
    }

    // BAK-92 regression: a queued task whose result is written but NOT yet ingested
    // (outbox already archived, so no live outbox) must not be re-exported — otherwise
    // the worker runs it twice (e.g. a second Gmail draft / Shortcut story).
    @MainActor
    func test_export_skipsQueuedTask_whenLiveResultPending() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let area = Area(name: "Digital Licence")
        let list = TaskList(name: "DL", area: area)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued; t.actionType = .ticket
        t.list = list
        let run = AgentRun(task: t)
        run.requiresConnectedWorker = true
        t.agentRun = run
        ctx.insert(area); ctx.insert(list); ctx.insert(t); ctx.insert(run)
        io.live = []                 // worker already archived the outbox
        io.liveResults = ["u1"]      // result written, not yet ingested
        svc.exportWorkOrders(workingDir: "/kb/DL", area: "Digital Licence", project: "DL")
        XCTAssertTrue(io.written.isEmpty, "must not re-issue a duplicate while a result is pending ingest")
    }

    @MainActor
    func test_ingest_appliesExecuteResult_andArchives() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued
        ctx.insert(t)
        io.results = [(AgentResult(uid: "u1", mode: "execute", status: "done", actionType: nil,
            title: nil, body: nil, links: [TaskLink(label: "SC", url: "https://x")], summary: "done", error: nil),
            "/kb/DL/_agent/results/u1.json")]
        svc.ingestAgentResults(workingDir: "/kb/DL")
        XCTAssertEqual(t.stage, .needsReview)
        XCTAssertEqual(t.links.first?.url, "https://x")
        XCTAssertEqual(io.archived.count, 1)
    }

    @MainActor
    func test_ingest_normalizesExecuteDoneIntoRun_completedAndClearsFallback() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
        t.agentRun = run
        ctx.insert(t); ctx.insert(run)
        io.results = [(AgentResult(uid: "u1", mode: "execute", status: "done", actionType: nil,
            title: nil, body: nil, links: [TaskLink(label: "SC", url: "https://x")], summary: "Created it", error: nil),
            "/kb/DL/_agent/results/u1.json")]

        svc.ingestAgentResults(workingDir: "/kb/DL")

        XCTAssertEqual(t.stage, .needsReview)
        XCTAssertEqual(run.state, .completed)
        XCTAssertFalse(run.requiresConnectedWorker)
        XCTAssertEqual(run.orderedMessages.last?.kind, .result)
        XCTAssertEqual(run.orderedMessages.last?.content, "Created it")
        XCTAssertEqual(run.orderedMessages.last?.links.first?.url, "https://x")
    }

    @MainActor
    func test_ingest_materializesConnectedDrafts() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
        t.agentRun = run
        ctx.insert(t); ctx.insert(run)
        io.results = [(AgentResult(uid: "u1", mode: "execute", status: "done", actionType: nil,
            title: nil, body: nil, links: nil, summary: "Drafted", error: nil,
            drafts: [AgentDraftPayload(kind: "email", title: "Reply", path: "_agent/drafts/u1/reply.md")]),
            "/kb/DL/_agent/results/u1.json")]

        svc.ingestAgentResults(workingDir: "/kb/DL")

        XCTAssertEqual(run.drafts?.count, 1)
        XCTAssertEqual(run.drafts?.first?.kind, .email)
    }

    @MainActor
    func test_ingest_normalizesFailedIntoRun_failedAndRetainsFallback() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
        t.agentRun = run
        ctx.insert(t); ctx.insert(run)
        io.results = [(AgentResult(uid: "u1", mode: "execute", status: "failed", actionType: nil,
            title: nil, body: nil, links: nil, summary: nil, error: "network down"),
            "/kb/DL/_agent/results/u1.json")]

        svc.ingestAgentResults(workingDir: "/kb/DL")

        XCTAssertEqual(t.stage, .queued)                // stays for re-export
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.requiresConnectedWorker)      // retained so export retries
        XCTAssertEqual(run.orderedMessages.last?.kind, .error)
        XCTAssertTrue(run.orderedMessages.last?.content.contains("network down") ?? false)
    }

    @MainActor
    func test_ingest_normalizesPrepDoneIntoRun_queued() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .forAgent
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
        t.agentRun = run
        ctx.insert(t); ctx.insert(run)
        io.results = [(AgentResult(uid: "u1", mode: "prep", status: "done", actionType: "ticket_write",
            title: "Prepped", body: "notes", links: nil, summary: "ready", error: nil),
            "/kb/DL/_agent/results/u1.json")]

        svc.ingestAgentResults(workingDir: "/kb/DL")

        XCTAssertEqual(t.stage, .needsApproval)
        XCTAssertEqual(run.state, .queued)
        XCTAssertTrue(run.requiresConnectedWorker)      // retained for the execute pass
        XCTAssertEqual(run.orderedMessages.last?.kind, .progress)
    }

    @MainActor
    func test_ingest_normalizesDeclinedIntoRun_cancelled() throws {
        let io = StubIO(); let (svc, ctx) = try service(io)
        let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued; t.owner = .agent
        let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
        t.agentRun = run
        ctx.insert(t); ctx.insert(run)
        io.results = [(AgentResult(uid: "u1", mode: "execute", status: "declined", actionType: nil,
            title: nil, body: nil, links: nil, summary: "not enough context", error: nil),
            "/kb/DL/_agent/results/u1.json")]

        svc.ingestAgentResults(workingDir: "/kb/DL")

        XCTAssertEqual(t.owner, .me)
        XCTAssertEqual(t.stage, .planned)
        XCTAssertEqual(run.state, .cancelled)
        XCTAssertFalse(run.requiresConnectedWorker)
        XCTAssertEqual(run.orderedMessages.last?.kind, .error)
    }

    // BAK-84: ingest sweeps undecodable result files aside each run.
    @MainActor
    func test_ingest_quarantinesUndecodableResults() throws {
        let io = StubIO(); let (svc, _) = try service(io)
        svc.ingestAgentResults(workingDir: "/kb/DL")
        XCTAssertEqual(io.quarantineCalls, 1)
    }
}
