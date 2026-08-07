import XCTest
import SwiftData
@testable import MustardKit

final class VaultSweepParserTests: XCTestCase {
    func test_parse_happyPath() {
        let text = #"[{"title": "Revive SDK note", "body": "Stale since May.", "action_type": "vault_note"}]"#
        let result = VaultSweep.parse(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Revive SDK note")
        XCTAssertEqual(result[0].body, "Stale since May.")
    }

    func test_parse_codeFencedAndProseWrapped() {
        let text = """
        Here are my recommendations:
        ```json
        [{"title": "A"}, {"title": "B", "body": "b"}]
        ```
        Hope that helps!
        """
        let result = VaultSweep.parse(text)
        XCTAssertEqual(result.map(\.title), ["A", "B"])
        XCTAssertEqual(result[1].body, "b")
    }

    func test_parse_garbageReturnsEmpty() {
        XCTAssertEqual(VaultSweep.parse("I could not find anything."), [])
        XCTAssertEqual(VaultSweep.parse(""), [])
        XCTAssertEqual(VaultSweep.parse("[not json"), [])
    }

    func test_parse_capsAtFive() {
        let items = (1...8).map { #"{"title": "t\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(VaultSweep.parse("[\(items)]").count, 5)
    }

    func test_parse_readsConfidenceReasoningDraft() {
        let text = #"[{"title":"Reply","action_type":"draft_email","confidence":0.82,"reasoning":"asked by EOD","draft":"Hi Kamil,"}]"#
        let p = VaultSweep.parse(text)[0]
        XCTAssertEqual(p.actionType, "draft_email")
        XCTAssertEqual(p.confidence, 0.82, accuracy: 0.001)
        XCTAssertEqual(p.reasoning, "asked by EOD")
        XCTAssertEqual(p.draft, "Hi Kamil,")
    }

    func test_parse_defaultsAndClampsConfidence() {
        let missing = VaultSweep.parse(#"[{"title":"x"}]"#)[0]
        XCTAssertEqual(missing.confidence, 0.5, accuracy: 0.001)
        XCTAssertEqual(missing.reasoning, "")
        let over = VaultSweep.parse(#"[{"title":"x","confidence":1.8}]"#)[0]
        XCTAssertEqual(over.confidence, 1.0, accuracy: 0.001)
    }

    // MARK: - parseOutcome distinguishes "no recommendations" from "unparseable"

    func test_parseOutcome_proseWithNoBracketsIsUnparseable() {
        XCTAssertEqual(VaultSweep.parseOutcome("I could not find anything."), .unparseable)
        XCTAssertEqual(VaultSweep.parseOutcome(""), .unparseable)
    }

    func test_parseOutcome_truncatedJSONIsUnparseable() {
        XCTAssertEqual(VaultSweep.parseOutcome("[not json"), .unparseable)
    }

    func test_parseOutcome_emptyArrayIsProposalsNotUnparseable() {
        XCTAssertEqual(VaultSweep.parseOutcome("[]"), .proposals([]))
    }

    func test_parseOutcome_happyPathWrapsProposals() {
        let text = #"[{"title": "Revive SDK note", "body": "Stale since May."}]"#
        guard case .proposals(let proposals) = VaultSweep.parseOutcome(text) else {
            return XCTFail("expected .proposals for well-formed input")
        }
        XCTAssertEqual(proposals.map(\.title), ["Revive SDK note"])
    }

    func test_parse_isConsistentWithParseOutcome() {
        // `parse` stays the thin convenience wrapper existing call sites use.
        XCTAssertEqual(VaultSweep.parse(#"[{"title":"x"}]"#).map(\.title),
                        ["x"])
        XCTAssertEqual(VaultSweep.parse("garbage, no brackets"), [])
    }
}

final class VaultSweepPromptTests: XCTestCase {
    func test_prompt_ignoresAppInternalFolders() {
        XCTAssertTrue(VaultSweep.prompt.contains("_filed/"))
        XCTAssertTrue(VaultSweep.prompt.contains("_recs/"))
    }

    func test_prompt_hasChannelRoutingRule() {
        XCTAssertTrue(VaultSweep.prompt.contains("external partners"))
        XCTAssertTrue(VaultSweep.prompt.contains("never Slack"))
    }

    func test_prompt_enumeratesMultiItemDrafts() {
        XCTAssertTrue(VaultSweep.prompt.contains("one line per item"))
    }

    func test_prompt_demotesExternallyBlocked() {
        XCTAssertTrue(VaultSweep.prompt.contains("waiting on"))
    }

    func test_prompt_distinguishesTicketWriteFromCreateTask() {
        XCTAssertTrue(VaultSweep.prompt.contains("DRAFTING A NEW ticket"))
        XCTAssertTrue(VaultSweep.prompt.contains("EXISTING ticket"))
    }

    func test_executePrompt_includesDraftAsStartingPoint() {
        let p = VaultSweep.executePrompt(
            title: "Reply to Kamil", body: "He asked for the figures.",
            action: .draftEmail, draft: "Hi Kamil, here are the Q2 figures…"
        )
        XCTAssertTrue(p.contains("Hi Kamil, here are the Q2 figures…"))
        XCTAssertTrue(p.contains("Starting point"))
    }

    func test_executePrompt_emailPhrasingDiffersFromVaultNote() {
        let email = VaultSweep.executePrompt(title: "t", body: "b", action: .draftEmail)
        let note = VaultSweep.executePrompt(title: "t", body: "b", action: .vaultNote)
        XCTAssertTrue(email.lowercased().contains("email"))
        XCTAssertTrue(note.lowercased().contains("knowledge base"))
        XCTAssertNotEqual(email, note)
    }

    func test_executePrompt_gatedActionStaysDraftOnly() {
        let p = VaultSweep.executePrompt(title: "t", body: "b", action: .draftEmail)
        XCTAssertTrue(p.lowercased().contains("do not send"))
    }

    func test_executePrompt_withFeedbackAndPriorOutput_instructsRevision() {
        let p = VaultSweep.executePrompt(
            title: "t", body: "b", action: .vaultNote,
            feedback: "make it shorter", priorOutput: "A long previous draft."
        )
        XCTAssertTrue(p.contains("make it shorter"))
        XCTAssertTrue(p.contains("A long previous draft."))
        XCTAssertTrue(p.lowercased().contains("revis"))
    }

    func test_executePrompt_withoutFeedbackOrPrior_omitsRevisionBlock() {
        let p = VaultSweep.executePrompt(title: "t", body: "b", action: .vaultNote)
        XCTAssertFalse(p.contains("You previously produced"))
        XCTAssertFalse(p.contains("This is a revision."))
    }

    func test_executePrompt_emptyDraftFallsBackToBody() {
        let p = VaultSweep.executePrompt(
            title: "t", body: "The body text.", action: .vaultNote, draft: ""
        )
        XCTAssertTrue(p.contains("The body text."))
    }

    func test_classifyPrompt_includesTaskAndDeclineOption() {
        let p = VaultSweep.classifyPrompt(
            title: "Find Ruby's error screens",
            notes: "Liam asked where they live in Figma.",
            areaName: "Digital Licence")
        XCTAssertTrue(p.contains("Find Ruby's error screens"))
        XCTAssertTrue(p.contains("Liam asked"))
        XCTAssertTrue(p.contains("Digital Licence"))
        XCTAssertTrue(p.contains("\"ignore\""))      // decline path is offered
        XCTAssertTrue(p.contains("JSON array"))       // reuses VaultSweep.parse shape
    }

    func test_classifyPrompt_parsesBackThroughVaultSweepParse() {
        // The shape the prompt asks for must round-trip through the existing parser.
        let modelOutput = #"[{"title":"Locate error screens","body":"Search Figma","action_type":"vault_note","confidence":0.8,"reasoning":"clear ask","draft":"Steps: ..."}]"#
        let proposal = VaultSweep.parse(modelOutput).first
        XCTAssertEqual(proposal?.actionType, "vault_note")
        XCTAssertEqual(proposal?.title, "Locate error screens")
    }
}


@MainActor
final class AgentServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        return ModelContext(container)
    }

    // MARK: - Sweep

    func test_sweep_insertsPendingRecommendations() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in
            ClaudeResult(ok: true, text: #"[{"title": "One"}, {"title": "Two"}]"#)
        }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/tmp/vault")

        let recs = try ctx.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2)
        XCTAssertTrue(recs.allSatisfy { $0.decision == .pending })
        XCTAssertNil(service.lastError)
    }

    func test_sweep_failureSetsError_insertsNothing() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: false, text: "401") }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/tmp/vault")

        XCTAssertNotNil(service.lastError)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }

    // Malformed/unparseable model output must not look like a silent no-op — it gets
    // a distinct, user-visible message from a genuinely empty (but well-formed) sweep.
    func test_sweep_unparseableOutput_setsCouldNotParseError() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: true, text: "I looked but found nothing worth flagging.") }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/tmp/vault")

        XCTAssertEqual(service.lastError, "Sweep returned output Mustard couldn't parse")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }

    func test_sweep_emptyArrayOutput_setsNoRecommendationsError() async throws {
        let ctx = try makeContext()
        let stub: ClaudeRun = { _, _ in ClaudeResult(ok: true, text: "[]") }
        let service = AgentService(context: ctx, claude: stub)
        await service.sweep(vaultPath: "/tmp/vault")

        XCTAssertEqual(service.lastError, "Sweep returned no parseable recommendations")
    }

    func test_archiveStaleMeetingTasks_completesOld_retagsSource_leavesRecent() throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "[]") })
        let old = MustardTask(title: "old"); old.source = "meeting"
        old.sourceURL = "DL/meetings/2026/05/2026-05-01-planning.md"
        let recent = MustardTask(title: "recent"); recent.source = "meeting"
        recent.sourceURL = "DL/meetings/2026/06/2026-06-23-standup.md"
        ctx.insert(old); ctx.insert(recent)

        let count = service.archiveStaleMeetingTasks(
            now: ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(old.status, .done)
        XCTAssertEqual(old.source, "meeting:archived")
        XCTAssertEqual(recent.status, .inbox, "recent meeting task is untouched")
        XCTAssertEqual(recent.source, "meeting")
    }

    // MARK: - decide(approved) — board promotion (ADR-0010)

    func test_approve_outwardAction_stagesQueuedAgentTask_noClaude() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        // draft_email is an outward/connector action — staged for the decoupled session.
        let rec = Recommendation(title: "Reply to Kamil", actionType: "draft_email",
                                 vaultPath: "/v", confidence: 0.8, draft: "Hi Kamil,")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        XCTAssertFalse(called, "outward actions don't run headless — they queue")
        XCTAssertEqual(rec.decision, .approved)
        let tasks = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.stage, .queued)
        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.actionType, .draftEmail)
        XCTAssertEqual(task.notes, "Hi Kamil,")
        XCTAssertEqual(task.delegation, rec)
        XCTAssertEqual(rec.task, task)
    }

    func test_approve_vaultNote_runsHeadless_marksTaskDone() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "Filed the note.") })
        let rec = Recommendation(title: "Update SDK note", actionType: "vault_note", vaultPath: "/v")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        XCTAssertEqual(rec.executionState, .finished)
        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.stage, .done)
        XCTAssertEqual(task.status, .done)
        XCTAssertNotNil(task.completedAt)
    }

    func test_approve_vaultNote_failure_leavesTaskQueued_setsError() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: false, text: "boom") })
        let rec = Recommendation(title: "Update SDK note", actionType: "vault_note", vaultPath: "/v")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        XCTAssertEqual(rec.executionState, .failed)
        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.stage, .queued, "a failed headless run leaves the task queued")
        XCTAssertNotEqual(task.status, .done)
        XCTAssertNotNil(service.lastError)
    }

    func test_approve_createTask_insertsInboxMeTask_noClaude() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Find Ruby's error screens", actionType: "create_task",
                                 vaultPath: "/v", draft: "Locate in Figma; answer Liam's Qs")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        XCTAssertFalse(called)
        let tasks = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.title, "Find Ruby's error screens")
        XCTAssertEqual(task.notes, "Locate in Figma; answer Liam's Qs")
        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .inbox)
        XCTAssertEqual(task.status, .inbox)
    }

    // BAK-91: a create_task rec referencing a Shortcut/Jira link should carry that
    // link onto the materialized task (so there's somewhere to see/open it).
    func test_approve_createTask_capturesReferencedLink() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Review the story", actionType: "create_task",
                                 vaultPath: "/v",
                                 draft: "See https://app.shortcut.com/codeheroes/story/9001 and reply",
                                 sourceURL: "https://app.shortcut.com/codeheroes/story/9001")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.links.map(\.url), ["https://app.shortcut.com/codeheroes/story/9001"])
        XCTAssertEqual(task.links.first?.label, "Shortcut")
        XCTAssertEqual(task.sourceURL, "https://app.shortcut.com/codeheroes/story/9001")
    }

    func test_approve_fyi_doesNothing() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "FYI", actionType: "fyi", vaultPath: "/v")
        ctx.insert(rec)

        await service.decide(rec, .approved)

        XCTAssertFalse(called)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MustardTask>()).count, 0)
    }

    // MARK: - decide(scheduled / selfExecute / denied)

    func test_decide_scheduled_createsScheduledMeTask_atNextNineAM() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Prep slides", actionType: "vault_note", vaultPath: "/v", draft: "outline")
        ctx.insert(rec)

        await service.decide(rec, .scheduled)

        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .scheduled)
        let when = try XCTUnwrap(task.scheduledAt)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: when)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertGreaterThan(when, .now)
    }

    func test_decide_selfExecute_createsPlannedMeTask() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "I'll handle it", actionType: "draft_email", vaultPath: "/v")
        ctx.insert(rec)

        await service.decide(rec, .selfExecute)

        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
    }

    func test_decide_denyDelegatedRec_returnsTaskToYou_planned() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let task = MustardTask(title: "T", owner: .agent); task.stage = .forAgent
        let rec = Recommendation(title: "R", actionType: "vault_note")
        rec.task = task; task.delegation = rec
        ctx.insert(task); ctx.insert(rec)

        await service.decide(rec, .denied)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
    }

    // MARK: - delegate

    func test_delegate_handsTaskToAgent_atForAgent_andQueuesRunWithDelegationMessage() throws {
        let ctx = try! makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let task = MustardTask(title: "Do this", owner: .me)
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))  // BAK-90: area required
        ctx.insert(task)

        service.delegate(task)

        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .forAgent)
        XCTAssertNil(service.lastHint)

        let run = try XCTUnwrap(task.agentRun)
        XCTAssertEqual(run.state, .queued)
        XCTAssertFalse(run.requiresConnectedWorker)
        XCTAssertEqual(run.orderedMessages.map(\.kind), [.delegation])
        XCTAssertEqual(run.orderedMessages.map(\.role), [.human])
        XCTAssertEqual(run.orderedMessages.map(\.sequence), [0])
        XCTAssertEqual(run.orderedMessages.map(\.content), ["Do this"])

        try ctx.save()
        let fetchedRun = try XCTUnwrap(ctx.fetch(FetchDescriptor<AgentRun>()).first)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AgentRun>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AgentMessage>()).count, 1)
        XCTAssertEqual(fetchedRun.task, task)
        XCTAssertEqual(task.agentRun, fetchedRun)
    }

    // BAK-90: an area-less task can't be handed off (the bridge export filters by area,
    // so it would silently never route). Block it and surface a hint instead.
    func test_delegate_areaLessTask_isBlocked_withHint() throws {
        let ctx = try! makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let task = MustardTask(title: "Prep release DLV 2.21.0", owner: .me)  // no area
        task.stage = .planned
        ctx.insert(task)

        service.delegate(task)

        XCTAssertEqual(task.owner, .me, "owner must not flip without an area")
        XCTAssertEqual(task.stage, .planned, "stage must not change without an area")
        XCTAssertNotNil(service.lastHint, "should surface a 'needs an area' hint")
        XCTAssertNil(task.agentRun)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<AgentRun>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<AgentMessage>()).isEmpty)
    }

    func test_delegate_existingRun_appendsCurrentRequest_andPreservesHistoryAndSession() throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let task = MustardTask(title: "Prep release", owner: .me)
        task.notes = "Check the changelog and draft release notes."
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        ctx.insert(task)

        service.delegate(task)
        let originalRun = try XCTUnwrap(task.agentRun)
        originalRun.providerSessionID = "session-123"
        originalRun.state = .completed
        originalRun.requiresConnectedWorker = true
        let priorResult = AgentMessage(
            run: originalRun,
            sequence: 1,
            role: .agent,
            kind: .result,
            content: "Earlier result"
        )
        ctx.insert(priorResult)
        originalRun.messages = (originalRun.messages ?? []) + [priorResult]
        task.owner = .me
        task.stage = .planned
        task.title = "Prep release 2.0"
        task.notes = "Use the edited changelog and include migration notes."

        service.delegate(task)

        XCTAssertEqual(task.agentRun, originalRun)
        XCTAssertEqual(originalRun.providerSessionID, "session-123")
        XCTAssertEqual(originalRun.state, .queued)
        XCTAssertFalse(originalRun.requiresConnectedWorker)
        XCTAssertEqual(originalRun.orderedMessages.map(\.kind), [.delegation, .result, .delegation])
        XCTAssertEqual(originalRun.orderedMessages.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(originalRun.orderedMessages.last?.content,
                       "Prep release 2.0\n\nUse the edited changelog and include migration notes.")
        XCTAssertNil(originalRun.completedAt)
        XCTAssertNil(originalRun.lastOutcomeRaw)
        XCTAssertNil(originalRun.lastError)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AgentRun>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AgentMessage>()).count, 3)
    }

    func test_delegate_agentOwnedActiveTask_isStrictNoOp() throws {
        let ctx = try makeContext()
        var persistCalls = 0
        let service = AgentService(
            context: ctx,
            claude: { _, _ in ClaudeResult(ok: true, text: "x") },
            persist: { persistCalls += 1; try ctx.save() }
        )
        let task = MustardTask(title: "Already running", owner: .agent)
        task.stage = .inProgress
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        let run = AgentRun(task: task)
        run.state = .running
        run.providerSessionID = "active-session"
        task.agentRun = run
        let message = AgentMessage(
            run: run, sequence: 0, role: .human, kind: .delegation, content: "Original"
        )
        ctx.insert(task); ctx.insert(run); ctx.insert(message)

        service.delegate(task)

        XCTAssertEqual(task.owner, .agent)
        XCTAssertEqual(task.stage, .inProgress)
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(run.providerSessionID, "active-session")
        XCTAssertEqual(run.orderedMessages.map(\.content), ["Original"])
        XCTAssertEqual(persistCalls, 0)
    }

    func test_delegate_doneHumanTask_isStrictNoOp() throws {
        let ctx = try makeContext()
        var persistCalls = 0
        let service = AgentService(
            context: ctx,
            claude: { _, _ in ClaudeResult(ok: true, text: "x") },
            persist: { persistCalls += 1; try ctx.save() }
        )
        let task = MustardTask(title: "Finished", owner: .me)
        task.stage = .done
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        ctx.insert(task)

        service.delegate(task)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .done)
        XCTAssertNil(task.agentRun)
        XCTAssertEqual(persistCalls, 0)
    }

    func test_delegate_firstSaveFailure_rollsBackRunMessageAndTask_preservesUnrelatedEdit() throws {
        let ctx = try makeContext()
        let service = AgentService(
            context: ctx,
            claude: { _, _ in ClaudeResult(ok: true, text: "x") },
            persist: { throw CocoaError(.fileWriteUnknown) }
        )
        let task = MustardTask(title: "Hand this off", owner: .me)
        task.stage = .planned
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        let unrelated = MustardTask(title: "Before")
        ctx.insert(task); ctx.insert(unrelated)
        unrelated.title = "Keep this edit"

        service.delegate(task)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertNil(task.agentRun)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<AgentRun>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<AgentMessage>()).isEmpty)
        XCTAssertEqual(unrelated.title, "Keep this edit")
        XCTAssertNotNil(service.lastError)
        XCTAssertNotNil(service.lastHint)
    }

    func test_delegate_existingRunSaveFailure_restoresTerminalStateAndHistory_preservesUnrelatedEdit() throws {
        let ctx = try makeContext()
        let service = AgentService(
            context: ctx,
            claude: { _, _ in ClaudeResult(ok: true, text: "x") },
            persist: { throw CocoaError(.fileWriteUnknown) }
        )
        let task = MustardTask(title: "Edited request", owner: .me)
        task.notes = "New notes"
        task.stage = .planned
        task.list = TaskList(name: "DL", area: Area(name: "Digital Licence"))
        let run = AgentRun(task: task)
        run.state = .completed
        run.providerSessionID = "session-1"
        run.requiresConnectedWorker = true
        run.completedAt = Date(timeIntervalSince1970: 10)
        run.lastOutcomeRaw = "completed"
        run.lastError = "old error"
        task.agentRun = run
        let original = AgentMessage(
            run: run, sequence: 0, role: .human, kind: .delegation, content: "Old request"
        )
        let unrelated = MustardTask(title: "Before")
        ctx.insert(task); ctx.insert(run); ctx.insert(original); ctx.insert(unrelated)
        unrelated.title = "Keep this edit"

        service.delegate(task)

        XCTAssertEqual(task.owner, .me)
        XCTAssertEqual(task.stage, .planned)
        XCTAssertEqual(task.agentRun, run)
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.providerSessionID, "session-1")
        XCTAssertTrue(run.requiresConnectedWorker)
        XCTAssertEqual(run.completedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(run.lastOutcomeRaw, "completed")
        XCTAssertEqual(run.lastError, "old error")
        XCTAssertEqual(run.orderedMessages.map(\.content), ["Old request"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AgentMessage>()).count, 1)
        XCTAssertEqual(unrelated.title, "Keep this edit")
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - applyTrust

    func test_applyTrust_trusted_autoApprovesNonGated_promotesTask() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "done") })
        let rec = Recommendation(title: "Note", actionType: "vault_note", vaultPath: "/v", confidence: 0.9)
        ctx.insert(rec)

        await service.applyTrust(.trusted)

        XCTAssertEqual(rec.decision, .approved)
        let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MustardTask>()).first)
        XCTAssertEqual(task.stage, .done)   // vault note ran headless to done
    }

    func test_applyTrust_neverTouchesGatedActions() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Email Kamil", actionType: "draft_email", vaultPath: "/v", confidence: 0.95)
        ctx.insert(rec)

        await service.applyTrust(.autonomous)

        XCTAssertEqual(rec.decision, .pending)
        XCTAssertFalse(called)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MustardTask>()).count, 0)
    }

    func test_applyTrust_skipsLowConfidence_evenTrusted() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Shaky", actionType: "vault_note", vaultPath: "/v", confidence: 0.3)
        ctx.insert(rec)

        await service.applyTrust(.trusted)

        XCTAssertEqual(rec.decision, .pending)
        XCTAssertFalse(called)
    }

    func test_applyTrust_skipsFyi() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Heads up", actionType: "fyi", vaultPath: "/v", confidence: 0.9)
        ctx.insert(rec)

        await service.applyTrust(.autonomous)

        XCTAssertFalse(called)
        XCTAssertEqual(rec.decision, .pending)
    }

    func test_applyTrust_neverAutoActionsIgnoreRecs() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "PO Review", actionType: "ignore",
                                 vaultPath: "/tmp/vault", confidence: 0.95)
        ctx.insert(rec)

        await service.applyTrust(.trusted)

        XCTAssertFalse(called, "ignore recs must never auto-action")
        XCTAssertEqual(rec.decision, .pending)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MustardTask>()).count, 0)
    }

    func test_applyTrust_skipsDelegatedRecs() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        // A delegated rec (has a task link) is not auto-actioned by the trust sweep.
        let task = MustardTask(title: "Delegated work", owner: .agent)
        let rec = Recommendation(title: "Do it", actionType: "vault_note", confidence: 0.9)
        rec.task = task; task.delegation = rec
        ctx.insert(task); ctx.insert(rec)

        await service.applyTrust(.trusted)

        XCTAssertFalse(called)
        XCTAssertEqual(rec.decision, .pending)
    }

    func test_applyTrust_createTask_insertsMeTask_noClaude() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "Do the thing", actionType: "create_task", vaultPath: "/v", confidence: 0.9)
        ctx.insert(rec)

        await service.applyTrust(.trusted)

        XCTAssertFalse(called)
        let tasks = try ctx.fetch(FetchDescriptor<MustardTask>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.stage, .inbox)
    }

    // MARK: - grounded prompt + comment/snooze

    func test_approve_vaultNote_buildsGroundedPrompt_includingDraftAndComment() async throws {
        let ctx = try makeContext()
        var captured = ""
        let service = AgentService(context: ctx, claude: { prompt, _ in
            captured = prompt; return ClaudeResult(ok: true, text: "ok")
        })
        let rec = Recommendation(title: "Note", actionType: "vault_note", vaultPath: "/v", draft: "Body draft")
        ctx.insert(rec)
        service.comment(rec, "keep it under 100 words")

        await service.decide(rec, .approved)

        XCTAssertTrue(captured.contains("Body draft"))
        XCTAssertTrue(captured.contains("keep it under 100 words"))
    }

    func test_commentAndSnooze() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let rec = Recommendation(title: "x", vaultPath: "/v")
        ctx.insert(rec)
        service.comment(rec, "make it shorter")
        let until = Date.now.addingTimeInterval(3600)
        service.snooze(rec, until: until)
        XCTAssertEqual(rec.comment, "make it shorter")
        XCTAssertEqual(rec.snoozedUntil, until)
        XCTAssertEqual(rec.decision, .pending)
    }

    // MARK: - keep (FYI filing)

    func test_keep_fyi_appendsLog_noClaude() async throws {
        let ctx = try makeContext()
        var called = false
        let service = AgentService(context: ctx, claude: { _, _ in called = true; return ClaudeResult(ok: true, text: "x") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recommendation(title: "Standup moved", body: "now 9:30", actionType: "fyi", vaultPath: dir.path)
        ctx.insert(rec)

        service.keep(rec)

        XCTAssertFalse(called)
        XCTAssertEqual(rec.decision, .approved)
        let log = try String(contentsOf: InboxLog.logURL(workingDirectory: dir.path), encoding: .utf8)
        XCTAssertTrue(log.contains("Standup moved"))
        XCTAssertTrue(log.contains("now 9:30"))
    }

    func test_keep_appends_doesNotClobberExisting() async throws {
        let ctx = try makeContext()
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "x") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Recommendation(title: "First", actionType: "fyi", vaultPath: dir.path)
        let b = Recommendation(title: "Second", actionType: "fyi", vaultPath: dir.path)
        ctx.insert(a); ctx.insert(b)

        service.keep(a); service.keep(b)

        let log = try String(contentsOf: InboxLog.logURL(workingDirectory: dir.path), encoding: .utf8)
        XCTAssertTrue(log.contains("First"))
        XCTAssertTrue(log.contains("Second"))
    }

    // MARK: - ingestInbox

    func test_ingestInbox_reclassifiesGmailJiraNotificationToJiraSource() async throws {
        let ctx = try makeContext()
        let dir = NSTemporaryDirectory() + "mustard-wf-\(UUID().uuidString)"
        let recs = dir + "/_recs"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = #"{"source":"gmail","project":"DL","sourceItemID":"t","sourceEventID":"e1","sourceContext":"Jira · DLA-5280 · mentioned","title":"Confirm DLA-5280 status","body":"b","actionType":"ticket_write","confidence":0.8,"reasoning":"r","draft":"d"}"#
        try json.write(toFile: recs + "/e1.json", atomically: true, encoding: .utf8)
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "[]") })

        await service.ingestInbox(workingDirectory: dir)

        let stored = try ctx.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.source, "jira", "a Gmail-delivered Jira notification should be stored as source=jira")
    }

    // Malformed rec files used to be dropped with zero trace. Surface the count so
    // Leon can tell "nothing new" apart from "N files were silently unreadable."
    func test_ingestInbox_malformedRecFiles_surfacesSkipCountInLastError() async throws {
        let ctx = try makeContext()
        let dir = NSTemporaryDirectory() + "mustard-wf-\(UUID().uuidString)"
        let recs = dir + "/_recs"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{ not valid json".write(toFile: recs + "/bad.json", atomically: true, encoding: .utf8)
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "[]") })

        await service.ingestInbox(workingDirectory: dir)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Recommendation>()).count, 0)
        XCTAssertEqual(service.lastError, "1 file skipped (malformed)")
    }

    func test_ingestInbox_multipleMalformedRecFiles_pluralizesSkipMessage() async throws {
        let ctx = try makeContext()
        let dir = NSTemporaryDirectory() + "mustard-wf-\(UUID().uuidString)"
        let recs = dir + "/_recs"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{ not valid json".write(toFile: recs + "/bad1.json", atomically: true, encoding: .utf8)
        try "also not valid".write(toFile: recs + "/bad2.json", atomically: true, encoding: .utf8)
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "[]") })

        await service.ingestInbox(workingDirectory: dir)

        XCTAssertEqual(service.lastError, "2 files skipped (malformed)")
    }

    func test_ingestInbox_allValid_doesNotSetLastError() async throws {
        let ctx = try makeContext()
        let dir = NSTemporaryDirectory() + "mustard-wf-\(UUID().uuidString)"
        let recs = dir + "/_recs"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = #"{"source":"gmail","project":"DL","sourceItemID":"t","sourceEventID":"e1","sourceContext":"","title":"x","body":"b","actionType":"fyi","confidence":0.5,"reasoning":"r","draft":"d"}"#
        try json.write(toFile: recs + "/a.json", atomically: true, encoding: .utf8)
        let service = AgentService(context: ctx, claude: { _, _ in ClaudeResult(ok: true, text: "[]") })

        await service.ingestInbox(workingDirectory: dir)

        XCTAssertNil(service.lastError)
    }
}
