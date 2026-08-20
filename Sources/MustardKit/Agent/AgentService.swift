import Foundation
import SwiftData
import Observation

/// Orchestrates the agent loop: sweep → recommendations → decision → board task.
/// Approving a recommendation PROMOTES it onto the board (no review gate, no
/// OutputCard — output review lives in the board's Needs Review column). In-vault
/// actions still run headless via claude; outward actions stage at `queued` for a
/// decoupled connected session (ADR-0010). Serial: one claude invocation at a time
/// (subscription-friendly).
@MainActor
@Observable
public final class AgentService {
    private struct DelegationRunSnapshot {
        let state: AgentRunState
        let requiresConnectedWorker: Bool
        let completedAt: Date?
        let lastOutcomeRaw: String?
        let lastError: String?
        let lastActivityAt: Date
        let nextAttemptAt: Date?
        let autoRetryCount: Int
    }

    public private(set) var isSweeping = false
    public private(set) var isExecuting = false
    public private(set) var lastError: String?
    /// Title of the recommendation currently executing (drives the hover panel).
    public private(set) var currentTitle: String?
    /// Digest of the last meeting-task import (e.g. "imported 3 meeting tasks (2 clients)").
    public private(set) var lastMeetingSummary: String?
    /// Summary of the most recent manual Code Heroes decision queue import.
    public private(set) var lastCodeHeroesImportSummary: String?
    /// Code Heroes queue import feedback, kept separate from the agent loop's error state.
    public private(set) var lastCodeHeroesImportError: String?
    /// Synchronous for now; exposed so a future UI can disable its import action.
    public private(set) var isImportingCodeHeroesQueue = false
    /// Transient guidance for the user (not a failure) — e.g. a blocked hand-off needing
    /// a client area first (BAK-90). Surfaced as a calm banner, cleared on the next success.
    public private(set) var lastHint: String?

    private let context: ModelContext
    private let claude: ClaudeRun
    private let bridge: BridgeIO
    private let executionGate: AgentExecutionGate
    private let codeHeroesActionRunner: CodeHeroesDecisionActionRunning
    private let persist: () throws -> Void
    private let busyHint = "The agent is finishing another task. This work will stay queued and retry shortly."

    public init(context: ModelContext, claude: @escaping ClaudeRun = ClaudeRunner.run,
                bridge: BridgeIO = FileBridgeIO(),
                executionGate: AgentExecutionGate? = nil,
                persist: (() throws -> Void)? = nil,
                codeHeroesActionRunner: CodeHeroesDecisionActionRunning? = nil) {
        self.context = context
        self.claude = claude
        self.bridge = bridge
        self.executionGate = executionGate ?? AgentExecutionGate()
        self.codeHeroesActionRunner = codeHeroesActionRunner ?? ProductionCodeHeroesDecisionActionRunner()
        self.persist = persist ?? { try context.save() }
    }

    /// Imports a reviewed Code Heroes queue through the read-only projection adapter.
    /// This is intentionally available even when `settings.enabled` is false:
    /// that preference is reserved for a later automatic-refresh opt-in. This
    /// method performs no connector, repository, export, or scheduler work.
    @discardableResult
    public func importCodeHeroesDecisionQueue(
        settings: CodeHeroesQueueSettings,
        now: Date = .now
    ) async -> CodeHeroesDecisionAdapter.ImportReport? {
        let repositoryRoot = settings.repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let queuePath = settings.queuePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty, !queuePath.isEmpty else {
            lastCodeHeroesImportSummary = nil
            lastCodeHeroesImportError = "Code Heroes import requires a repository root and queue file path."
            return nil
        }

        isImportingCodeHeroesQueue = true
        lastCodeHeroesImportError = nil
        defer { isImportingCodeHeroesQueue = false }

        let report = await CodeHeroesDecisionAdapter(
            context: context,
            repositoryRoot: URL(fileURLWithPath: repositoryRoot),
            now: { now }
        ).importQueue(at: URL(fileURLWithPath: queuePath))
        lastCodeHeroesImportSummary = report.summary
        lastCodeHeroesImportError = report.findings.first.map { "Code Heroes import: \($0.reason)" }
        return report
    }

    /// Approve and execute a Code Heroes projection through the same serial execution
    /// gate used by ordinary agent actions. The projection remains repository-owned;
    /// this method only changes Mustard's local lifecycle after the adapter responds.
    public func approveCodeHeroes(_ task: MustardTask) async {
        await performCodeHeroesAction(task, kind: .approveAndRun)
    }

    /// Ignore a Code Heroes decision without a second confirmation or a required reason.
    public func ignoreCodeHeroes(_ task: MustardTask) async {
        await performCodeHeroesAction(task, kind: .ignore)
    }

    /// Send a bounded adjustment comment and leave the decision active for revision.
    public func commentCodeHeroes(_ task: MustardTask, text: String) async {
        await performCodeHeroesAction(task, kind: .comment, comment: text)
    }

    /// Records one explicit, bounded feedback signal. A candidate is surfaced only
    /// after the recorder finds three comparable signals across distinct records;
    /// candidate tasks are proposals and never mutate a routine or policy.
    @discardableResult
    public func recordCodeHeroesFeedback(
        _ task: MustardTask,
        signal: CodeHeroesFeedbackSignal,
        reason: String? = nil,
        now: Date = .now
    ) -> CodeHeroesFeedbackRecordResult? {
        do {
            let result = try CodeHeroesFeedbackRecorder.record(task: task, signal: signal, reason: reason, now: now)
            task.notes = boundedActionNote(task.notes, "Feedback recorded: \(signal.rawValue)")
            for candidate in result.candidates {
                upsertFeedbackCandidate(candidate, sourceTask: task)
            }
            _ = saveCodeHeroes("Could not persist Code Heroes feedback")
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func performCodeHeroesAction(
        _ task: MustardTask,
        kind: CodeHeroesDecisionActionKind,
        comment: String? = nil
    ) async {
        guard CodeHeroesDecisionPolicy.isProjection(task), task.stage.isOpen else { return }
        guard !isExecuting else {
            lastHint = busyHint
            return
        }
        let request: CodeHeroesDecisionActionRequest
        let settings: CodeHeroesQueueSettings
        do {
            request = try CodeHeroesDecisionActionRequestBuilder.make(task: task, action: kind, comment: comment)
            settings = try CodeHeroesDecisionActionRequestBuilder.settings(for: task)
        } catch {
            lastError = error.localizedDescription
            task.stage = .needsReview
            _ = saveCodeHeroes("Could not prepare the Code Heroes action")
            return
        }
        guard let token = executionGate.tryAcquire(owner: "Code Heroes decision") else {
            lastHint = busyHint
            return
        }
        defer { executionGate.release(token) }
        let previousStage = task.stage
        task.owner = .agent
        task.stage = .inProgress
        guard saveCodeHeroes("Could not start the Code Heroes action") else {
            task.stage = previousStage
            return
        }
        lastError = nil
        lastHint = nil
        isExecuting = true
        currentTitle = task.title
        defer { isExecuting = false; currentTitle = nil }

        let result = await codeHeroesActionRunner.run(request: request, settings: settings)
        switch result.status {
        case "completed":
            task.tags = Array(Set(task.tags + ["response:completed"])).sorted()
            task.markDone()
        case "ignored":
            task.tags = Array(Set(task.tags + ["response:ignored"])).sorted()
            task.markDone()
        case "commented":
            task.tags = Array(Set(task.tags + ["response:commented"])).sorted()
            task.stage = .needsInput
            task.notes = boundedActionNote(task.notes, "Comment sent · awaiting revision: \(result.message)")
        case "blocked", "conflict":
            task.tags = Array(Set(task.tags + ["response:blocked"])).sorted()
            task.stage = .needsReview
            task.notes = boundedActionNote(task.notes, "Code Heroes action blocked: \(result.message)")
            lastError = result.message
        default:
            task.tags = Array(Set(task.tags + ["response:failed"])).sorted()
            task.stage = .needsReview
            task.notes = boundedActionNote(task.notes, "Code Heroes action failed: \(result.message)")
            lastError = result.message
        }
        _ = saveCodeHeroes("Could not persist the Code Heroes action result")
    }

    private func boundedActionNote(_ existing: String, _ addition: String) -> String {
        String((existing + "\n" + addition).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_600))
    }

    private func upsertFeedbackCandidate(_ candidate: CodeHeroesFeedbackCandidate, sourceTask: MustardTask) {
        let tasks = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        let task: MustardTask
        if let existing = tasks.first(where: { $0.uid == candidate.taskUID }) {
            task = existing
        } else {
            task = MustardTask(title: "Review Code Heroes learning suggestion", owner: .agent)
            context.insert(task)
        }
        task.uid = candidate.taskUID
        task.title = "Review Code Heroes learning suggestion"
        task.notes = candidate.notes
        task.owner = .agent
        task.stage = .needsReview
        task.priority = .normal
        task.source = "codeheroes:feedback-candidate"
        task.sourceURL = (try? CodeHeroesDecisionActionRequestBuilder.repositoryRoot(for: sourceTask))
            .map { $0.appendingPathComponent("operations/feedback/candidates/\(candidate.candidateID).md").path }
        task.sourceContext = "candidate_id=\(candidate.candidateID);signal=\(candidate.signal.rawValue);project=\(candidate.projectID);source_routine=\(candidate.sourceRoutine)"
        task.tags = ["codeheroes", "feedback", "feedback-candidate", "human-action"]
    }

    @discardableResult
    private func saveCodeHeroes(_ prefix: String) -> Bool {
        do {
            try persist()
            return true
        } catch {
            lastError = "\(prefix): \(error.localizedDescription)"
            return false
        }
    }

    /// Manual vault sweep: ask claude for recommendations, ingest them through the
    /// shared pipeline (so manual sweeps dedupe too). Kept as the command-bar /
    /// console entry point during the multi-source transition.
    public func sweep(vaultPath: String) async {
        guard !isSweeping, !vaultPath.isEmpty else { return }
        isSweeping = true
        lastError = nil
        defer { isSweeping = false }

        guard let result = await runClaude(
            VaultSweep.prompt,
            workingDirectory: vaultPath,
            owner: "source sweep"
        ) else { return }
        guard result.ok else {
            lastError = "Sweep failed: \(result.text)"
            return
        }
        let project = URL(fileURLWithPath: vaultPath).lastPathComponent
        switch VaultSweep.parseOutcome(result.text) {
        case .unparseable:
            lastError = "Sweep returned output Mustard couldn't parse"
        case .proposals(let raw):
            let proposals = raw.map { SourceProposal(vault: $0, project: project) }
            if proposals.isEmpty {
                lastError = "Sweep returned no parseable recommendations"
                return
            }
            ingest(proposals, vaultPath: vaultPath)
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "lastSweptAt")
            await applyTrust(Self.storedTrust())
        }
    }

    /// Harvest meeting tasks from the curated notes under `vaultRoot` and reflect
    /// completions back (bidirectional, idempotent — see `MeetingTaskSync`). Cheap
    /// file I/O + parsing, no model call; the app batches this local import hourly.
    public func importMeetingTasks(vaultRoot: String) {
        guard !vaultRoot.isEmpty else { return }
        let sync = MeetingTaskSync(context: context, io: FileVaultIO(rootPath: vaultRoot))
        let digest = sync.importTasks()
        if digest.imported > 0 || digest.completedFromVault > 0 || digest.syncedToVault > 0 {
            lastMeetingSummary = digest.summary
        }
    }

    /// One-time backlog prune (2026-06-24 spec): the meeting importer historically
    /// lifted the whole team's action items in as Leon's tasks. Mark every meeting
    /// task whose meeting is older than `days` as done and retag its source to
    /// `meeting:archived` — which keeps it deduping (so the stale lines don't
    /// re-import) while the write-back guard skips it (so the vault notes stay
    /// untouched). Run-once is the caller's responsibility. Returns the count archived.
    @discardableResult
    public func archiveStaleMeetingTasks(now: Date = .now, olderThanDays days: Int = 7) -> Int {
        let all = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        let stale = MeetingTaskCleanup.tasksToArchive(all, now: now, olderThanDays: days)
        for task in stale {
            task.markDone(now: now)
            task.source = "meeting:archived"
        }
        return stale.count
    }

    /// Scheduled multi-source sweep: run each enabled + due source serially through
    /// the shared pipeline, advance per-source scheduling state only on success, and
    /// run trust once at the end. Returns updated settings for the caller to persist.
    @discardableResult
    public func sweepDueSources(_ settings: SourceSettings, now: Date = .now) async -> SourceSettings {
        guard !isSweeping else { return settings }
        isSweeping = true
        defer { isSweeping = false }

        var updated = settings
        var didIngest = false
        for config in settings.sources where config.enabled {
            // Only the vault source runs locally; Gmail discovery is the cloud scout (ADR-0007).
            guard config.id == .vault else { continue }
            // State is keyed per (source, project) so KBs never clobber each other.
            let state = settings.state.first { $0.id == config.id && $0.project == config.project }
            guard SweepScheduler.isDue(
                lastSweptAt: state?.lastSweptAt, intervalHours: config.intervalHours, now: now
            ) else { continue }

            guard let result = await runClaude(
                VaultSweep.prompt,
                workingDirectory: config.workingDirectory,
                owner: "scheduled source sweep"
            ) else { continue }
            guard result.ok else {
                updated.upsertState(SourceState(id: config.id, project: config.project, lastSweptAt: state?.lastSweptAt, lastError: result.text))
                continue
            }
            switch VaultSweep.parseOutcome(result.text) {
            case .unparseable:
                // Don't advance lastSweptAt — treat unparseable output like a failed
                // run so the next due cycle retries rather than silently giving up.
                updated.upsertState(SourceState(
                    id: config.id, project: config.project, lastSweptAt: state?.lastSweptAt,
                    lastError: "Sweep returned output Mustard couldn't parse"))
            case .proposals(let raw):
                let proposals = raw.map { SourceProposal(vault: $0, project: config.project) }
                ingest(proposals, vaultPath: config.workingDirectory)
                updated.upsertState(SourceState(id: config.id, project: config.project, lastSweptAt: now, lastError: nil))
                didIngest = true
            }
        }
        if didIngest { await applyTrust(Self.storedTrust()) }
        return updated
    }

    /// Single insert pipeline shared by manual + scheduled sweeps: dedupe each
    /// proposal against existing recommendations (and ones accepted earlier in this
    /// batch), then insert non-duplicates with source identity stamped.
    /// Ingest the local routine's grounded recs from a KB folder's `_recs/` through the
    /// shared dedupe + insert pipeline. Files are local (the routine writes them directly
    /// — no git). vaultPath = the KB folder, so any later execution runs in-project.
    public func ingestInbox(workingDirectory: String) async {
        let result = InboxIngest.read(in: workingDirectory)
        if result.skippedCount > 0 {
            let noun = result.skippedCount == 1 ? "file" : "files"
            lastError = "\(result.skippedCount) \(noun) skipped (malformed)"
        }
        guard !result.proposals.isEmpty else { return }
        ingest(result.proposals, vaultPath: workingDirectory)
        await applyTrust(Self.storedTrust())
    }

    /// Export forAgent/queued tasks under one KB working dir to its `_agent/outbox/`,
    /// and cancel stale outbox files. Pure plan + injected IO. (area/project identify
    /// the KB; in the loop they come from each enabled SourceConfig's own
    /// `workingDirectory` + `AreaMapping.areaName(forProject:)` — see MustardApp.)
    public func exportWorkOrders(workingDir: String, area: String, project: String) {
        let all = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        // This dir handles tasks whose area maps here; the caller passes the dir/area/project.
        let target = BridgeExport.RouteTarget(workingDir: workingDir, project: project)
        let mine = all.filter { ($0.list?.area?.name ?? "") == area }
        guard let live = listedBridgeUIDs(workingDir: workingDir) else { return }
        let plan = BridgeExport.plan(
            tasks: mine, route: { _ in target },
            liveOutboxUIDs: [workingDir: live.outbox],
            liveResultUIDs: [workingDir: live.results], now: .now)
        for w in plan.writes { try? bridge.writeWorkOrder(w.order, workingDir: workingDir) }
        for c in plan.cancels { try? bridge.cancelWorkOrder(uid: c.uid, workingDir: workingDir) }
    }

    /// Export area-less connected-worker tasks to the default KB's outbox (F26,
    /// ADR-0011 addendum). The per-source `exportWorkOrders` filters by area, so an
    /// approved voice hand-off that inferred no client area is invisible to it and
    /// strands (BAK-90). This routes exactly those orphans — tasks with no area — to
    /// the injected default working dir instead, so the connected worker can still
    /// pick them up. `BridgeExport.plan` still applies the real gates (export stage +
    /// `requiresConnectedWorker`), so ordinary local tasks are never exported here.
    /// The default dir must be distinct from the enabled source dirs (it is — the
    /// meeting vault isn't a sweep source) so the two passes never cancel each other.
    public func exportAreaLessWork(workingDir: String, project: String) {
        guard !workingDir.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        let target = BridgeExport.RouteTarget(workingDir: workingDir, project: project)
        let orphans = all.filter { $0.list?.area == nil }
        guard let live = listedBridgeUIDs(workingDir: workingDir) else { return }
        let plan = BridgeExport.plan(
            tasks: orphans, route: { _ in target },
            liveOutboxUIDs: [workingDir: live.outbox],
            liveResultUIDs: [workingDir: live.results], now: .now)
        for w in plan.writes { try? bridge.writeWorkOrder(w.order, workingDir: workingDir) }
        for c in plan.cancels { try? bridge.cancelWorkOrder(uid: c.uid, workingDir: workingDir) }
    }

    /// BAK-94: if outbox/ or results/ cannot be listed, skip the whole export tick
    /// (writes *and* cancels). An empty set here would re-issue a live order.
    private func listedBridgeUIDs(workingDir: String) -> (outbox: Set<String>, results: Set<String>)? {
        let outbox = bridge.liveOutboxUIDs(workingDir: workingDir)
        let results = bridge.liveResultUIDs(workingDir: workingDir)
        guard case .listed(let outboxUIDs) = outbox,
              case .listed(let resultUIDs) = results else {
            lastError = "Could not list the agent bridge; skipping export this tick"
            return nil
        }
        return (outboxUIDs, resultUIDs)
    }

    /// Ingest `_agent/results/` for one KB working dir: apply each (guarded) and archive it.
    public func ingestAgentResults(workingDir: String) {
        let all = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        let byUID = Dictionary(all.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for (result, path) in bridge.readResults(workingDir: workingDir) {
            let task = byUID[result.uid]
            let outcome = BridgeIngest.apply(result, to: task)
            if outcome == .applied {
                if result.status == "failed" {
                    lastError = "Agent run failed: \(result.error ?? "unknown")"
                }
                if let task, let run = task.agentRun {
                    normalizeConnectedResult(result, into: run)
                }
            }
            try? bridge.archiveResult(path, workingDir: workingDir)
        }
        // Hygiene (BAK-84): move any undecodable / empty-uid result aside so it isn't
        // silently re-scanned every loop. (readResults already skipped it above.)
        bridge.quarantineUndecodableResults(workingDir: workingDir)
    }

    /// Fold a connected-worker bridge result into the task's durable conversation and run
    /// state, so bridge-executed work lands in the same timeline as local Claude turns.
    /// - execute done → `.result`, run `.completed`, clear the fallback flag
    /// - prep done    → `.progress`, run `.queued` (retain the flag for the execute pass)
    /// - declined     → `.error`, run `.cancelled`, clear the fallback flag
    /// - failed       → `.error`, run `.failed`, retain the flag so export re-issues (retry)
    private func normalizeConnectedResult(_ r: AgentResult, into run: AgentRun) {
        let now = Date.now
        let summary = (r.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (r.mode, r.status) {
        case ("execute", "done"):
            run.state = .completed
            run.completedAt = now
            run.requiresConnectedWorker = false
            run.lastError = nil
            AgentConversation.append(
                to: run, role: .agent, kind: .result,
                content: summary.isEmpty ? "Connected worker completed the task." : summary,
                links: r.links ?? [], now: now, in: context)

        case ("prep", "done"):
            run.state = .queued
            run.completedAt = nil
            AgentConversation.append(
                to: run, role: .agent, kind: .progress,
                content: summary.isEmpty ? "Connected worker prepared the task for approval." : summary,
                now: now, in: context)

        case (_, "declined"):
            run.state = .cancelled
            run.completedAt = now
            run.requiresConnectedWorker = false
            AgentConversation.append(
                to: run, role: .agent, kind: .error,
                content: "Connected worker passed on this" + (summary.isEmpty ? "." : ": \(summary)"),
                now: now, in: context)

        case (_, "failed"):
            run.state = .failed
            run.completedAt = now
            run.lastError = r.error ?? "Connected worker failed."
            // Retain requiresConnectedWorker so the next export re-issues the order (retry).
            AgentConversation.append(
                to: run, role: .agent, kind: .error,
                content: "Connected worker failed: \(r.error ?? "unknown").",
                now: now, in: context)

        default:
            break
        }

        AgentConversation.materializeDrafts(r.drafts ?? [], into: run, in: context)
    }

    private func ingest(_ proposals: [SourceProposal], vaultPath: String) {
        let existing = (try? context.fetch(FetchDescriptor<Recommendation>())) ?? []
        var accepted: [Recommendation] = []
        for raw in proposals {
            // Deterministic Mac-side normalization (logical source + PO-review→ignore)
            // BEFORE dedupe, so dedupe keys on the stable post-normalization source.
            let p = IngestNormalizer.normalize(raw)
            guard SourceDedupe.shouldInsert(p, against: existing + accepted) else { continue }
            let rec = Recommendation(from: p, vaultPath: vaultPath)
            context.insert(rec)
            accepted.append(rec)
        }
    }

    /// Trust level from settings (defaults to manual = nothing auto).
    static func storedTrust() -> TrustLevel {
        TrustLevel(rawValue: UserDefaults.standard.string(forKey: "trustLevel") ?? "") ?? .manual
    }

    /// Auto-process the pending backlog according to trust: approve eligible
    /// recommendations serially, promoting each onto the board via `decide`. There
    /// is no review gate (ADR-0010) — output review lives in the board's Needs Review
    /// column. Gated action types and awareness/ignored items are never touched.
    public func applyTrust(_ trust: TrustLevel) async {
        guard trust != .manual else { return }
        let pending = (try? context.fetch(FetchDescriptor<Recommendation>()))?
            .filter { $0.decision == .pending && $0.task == nil } ?? []  // delegated recs are handled on delegate()
        for rec in pending {
            if rec.action == .fyi || rec.action == .ignore { continue }   // awareness/ignored items are never auto-actioned
            guard TrustPolicy.shouldAutoApprove(
                actionType: rec.proposedActionType, trust: trust, confidence: rec.confidence
            ) else { continue }
            await decide(rec, .approved)
        }
    }

    /// Record feedback on a recommendation without deciding it (stays pending).
    public func comment(_ rec: Recommendation, _ text: String) {
        rec.comment = text
    }

    /// Keep an FYI: append it to the project's curated rolling log and clear it from the
    /// queue. No claude run, no OutputCard — filing is a direct local write.
    public func keep(_ rec: Recommendation) {
        let entry = InboxLog.entry(
            title: rec.title, body: rec.originalSource ?? rec.body,
            source: rec.source, sourceURL: rec.sourceURL, now: .now
        )
        let url = InboxLog.logURL(workingDirectory: rec.vaultPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + entry).write(to: url, atomically: true, encoding: .utf8)
        rec.decision = .approved
    }

    /// Hide a recommendation until `until`; it reappears in the queue after.
    public func snooze(_ rec: Recommendation, until: Date) {
        rec.snoozedUntil = until
    }

    /// Approving a create_task lands a real `.me` task in the inbox — no claude run.
    /// The task appearing is the confirmation (mirrors the "I'll do it" button).
    private func materializeTask(from rec: Recommendation) {
        let task = MustardTask(title: rec.title)
        task.notes = rec.draft.isEmpty ? rec.body : rec.draft
        task.stage = .inbox
        // BAK-91: carry the referenced item(s) so there's somewhere to see/open them —
        // any Shortcut/Jira link in the rec's text, plus the rec's own source URL.
        task.sourceURL = rec.sourceURL
        task.links = TaskLinkExtractor.referencedLinks(
            in: [rec.sourceURL, rec.draft, rec.body, rec.sourceContext, rec.originalSource])
        context.insert(task)
        ensureArea(task, fromProject: rec.project)
    }

    /// Stamp a newly-created task with the area resolved from the rec's `project`, so the
    /// board area filter and the bridge export can route it. Find-or-create the Area + a
    /// list in it; no-op if the task already has a list or the project doesn't map.
    private func ensureArea(_ task: MustardTask, fromProject project: String) {
        guard task.list == nil, let areaName = AreaMapping.areaName(forProject: project) else { return }
        let area = (try? context.fetch(FetchDescriptor<Area>()))?.first { $0.name == areaName }
            ?? { let a = Area(name: areaName); context.insert(a); return a }()
        if let list = (try? context.fetch(FetchDescriptor<TaskList>()))?.first(where: { $0.area?.name == areaName }) {
            task.list = list
        } else {
            let list = TaskList(name: areaName, area: area); context.insert(list); task.list = list
        }
    }

    /// The next 9:00 local time strictly after `now` (scheduling default for the
    /// .scheduled decision). Delegates to the shared, tested `SnoozeTargets`.
    private func nextNineAM(after now: Date = .now) -> Date {
        SnoozeTargets.nextNineAM(after: now)
    }

    /// Promote a recommendation onto the board: reuse an existing delegated task
    /// (`rec.task`) or create a new `.me` task, stamp provenance + the rec's draft,
    /// place it at `stage`/`owner`, and link rec↔task. Returns the task.
    @discardableResult
    private func promote(
        _ rec: Recommendation, to stage: TaskStage, owner: TaskOwner,
        scheduledAt: Date? = nil
    ) -> MustardTask {
        let task = rec.task ?? MustardTask(title: rec.title)
        let isNew = rec.task == nil
        task.notes = rec.draft.isEmpty ? rec.body : rec.draft
        task.actionType = rec.action
        task.confidence = rec.confidence
        task.migratedStage = true
        task.owner = owner
        if !task.stage.isOpen {
            // already done (e.g. headless vault note ran) — keep done stage
        } else {
            task.stage = stage
        }
        if let scheduledAt { task.scheduledAt = scheduledAt }
        // Defense in depth: a scheduled date must never leave the task in Inbox
        // (BAK-246). No-op when `stage` is already past the inbox, which is the
        // `.scheduled` / `.planned` decision path.
        PersonalBoard.normalizePlacement(task)
        rec.task = task
        task.delegation = rec
        if isNew {
            context.insert(task)
            ensureArea(task, fromProject: rec.project)  // route by area for export/board filter
        }
        return task
    }

    /// Record a decision and promote onto the board (ADR-0010). There is no review
    /// gate or OutputCard — approving stages the work as a board task.
    ///
    /// - `fyi` + approved → runs nothing (acknowledging is inert).
    /// - `createTask` + approved → a `.me` task in the inbox (`materializeTask`).
    /// - `vaultNote` + approved → runs headless via claude (it can reach the vault);
    ///   on success the task is marked DONE, on failure it stays `.queued` with the
    ///   error surfaced on `lastError`.
    /// - outward actions (`draftEmail`/`draftSlack`/`ticket`) + approved → a `.agent`
    ///   task at `.queued`; the decoupled connected session executes it later.
    /// - `.scheduled` → a `.me` task at `.scheduled` (next 9am).
    /// - `.selfExecute` → a `.me` task at `.planned`.
    /// - `.denied` → a delegated task returns to you (`.me`, `.planned` if not done).
    public func decide(_ rec: Recommendation, _ decision: RecommendationDecision) async {
        rec.decision = decision
        switch decision {
        case .denied:
            if let task = rec.task {
                task.owner = .me
                if task.stage.isOpen { task.stage = .planned }
            }
            return
        case .scheduled:
            promote(rec, to: .scheduled, owner: .me, scheduledAt: nextNineAM())
            return
        case .selfExecute:
            promote(rec, to: .planned, owner: .me)
            return
        case .approved:
            break
        default:
            return
        }

        // decision == .approved
        if rec.action == .fyi { return }                 // acknowledging an FYI runs nothing
        if rec.action == .createTask { materializeTask(from: rec); return }
        if rec.action == .vaultNote {
            await runVaultNote(rec)
            return
        }
        // Outward / connector actions: stage for the decoupled session, no claude run.
        promote(rec, to: .queued, owner: .agent)
    }

    /// Delegate a task to the agent ("Ask agent to do this"). The hand-off creates
    /// one durable queued run and its initial human transcript; re-delegating reuses
    /// that same run so provider session and message history remain intact.
    public func delegate(_ task: MustardTask) {
        // Agent-owned calls (including repeated clicks while active) are deliberately
        // inert. Human re-delegation is only legal from an explicit human lane.
        let humanStages: Set<TaskStage> = [.inbox, .planned, .scheduled, .inProgress, .blocked]
        guard task.owner == .me, humanStages.contains(task.stage) else { return }
        // BAK-90: require a client area first — the bridge export filters by area, so an
        // area-less hand-off would silently never route. Block it and surface a hint.
        guard PersonalBoard.canHandOffToAgent(task) else {
            lastHint = "“\(task.title)” needs a client area before the agent can take it — "
                + "file it under Digital Licence / Sales Buddi / Sandvik / Code Heroes first."
            return
        }
        let previousOwner = task.owner
        let previousStage = task.stage
        let previousRun = task.agentRun
        let previousRunState = previousRun.map {
            DelegationRunSnapshot(
                state: $0.state,
                requiresConnectedWorker: $0.requiresConnectedWorker,
                completedAt: $0.completedAt,
                lastOutcomeRaw: $0.lastOutcomeRaw,
                lastError: $0.lastError,
                lastActivityAt: $0.lastActivityAt,
                nextAttemptAt: $0.nextAttemptAt,
                autoRetryCount: $0.autoRetryCount
            )
        }

        lastHint = nil
        task.owner = .agent
        task.stage = .forAgent

        let run: AgentRun
        if let existing = previousRun {
            run = existing
        } else {
            run = AgentRun(task: task)
            task.agentRun = run
            context.insert(run)
        }

        let message = AgentMessage(
            run: run,
            sequence: (run.messages?.map(\.sequence).max() ?? -1) + 1,
            role: .human,
            kind: .delegation,
            content: delegationBody(for: task)
        )
        context.insert(message)
        run.state = .queued
        run.requiresConnectedWorker = false
        run.completedAt = nil
        run.lastOutcomeRaw = nil
        run.lastError = nil
        // A human re-delegation is a clean slate: drop any stale backoff window / retry
        // budget so the coordinator picks it up immediately with a full retry allowance.
        run.nextAttemptAt = nil
        run.autoRetryCount = 0
        run.lastActivityAt = message.createdAt

        do {
            try persist()
        } catch {
            task.owner = previousOwner
            task.stage = previousStage
            task.agentRun = previousRun
            run.messages?.removeAll { $0 === message }
            context.delete(message)
            if let previousRun, let snapshot = previousRunState {
                previousRun.state = snapshot.state
                previousRun.requiresConnectedWorker = snapshot.requiresConnectedWorker
                previousRun.completedAt = snapshot.completedAt
                previousRun.lastOutcomeRaw = snapshot.lastOutcomeRaw
                previousRun.lastError = snapshot.lastError
                previousRun.lastActivityAt = snapshot.lastActivityAt
                previousRun.nextAttemptAt = snapshot.nextAttemptAt
                previousRun.autoRetryCount = snapshot.autoRetryCount
            } else {
                context.delete(run)
            }
            lastError = "Could not save the agent hand-off: \(error.localizedDescription)"
            lastHint = "The hand-off wasn’t saved. Your task is still with you."
        }
    }

    /// Clear the transient hand-off hint (e.g. after a successful drop into an agent lane).
    public func clearHint() { lastHint = nil }

    /// Surface a transient hand-off hint (e.g. quick-add into an agent lane with no area
    /// scope to inherit — the task lands in Planned instead of stranding in the lane).
    public func setHint(_ message: String) { lastHint = message }

    /// Run an approved in-vault note headless via claude (it CAN reach the vault).
    /// Promote a board task either way; on success mark it DONE, on failure leave it
    /// at `.queued` and surface the error on `lastError` (no silent completion).
    private func runVaultNote(_ rec: Recommendation) async {
        // Stage the task first so a race with another execution can't strand the rec
        // (approved-but-no-task). If we're busy, it simply stays queued for a later run.
        let task = promote(rec, to: .queued, owner: .agent)
        guard !isExecuting else { return }
        guard let token = executionGate.tryAcquire(owner: "recommendation execution") else {
            lastHint = busyHint
            return
        }
        defer { executionGate.release(token) }
        if lastHint == busyHint { lastHint = nil }
        isExecuting = true
        currentTitle = rec.title
        rec.executionState = .running
        defer { isExecuting = false; currentTitle = nil }

        let result = await claude(
            VaultSweep.executePrompt(
                title: rec.title, body: rec.body, action: rec.action,
                draft: rec.draft, sourceContext: rec.sourceContext,
                feedback: rec.comment, priorOutput: ""
            ),
            rec.vaultPath
        )
        if result.ok {
            rec.executionState = .finished
            task.markDone()
        } else {
            rec.executionState = .failed
            lastError = "Execution failed: \(result.text)"
            task.stage = .queued
        }
    }

    private func runClaude(
        _ prompt: String,
        workingDirectory: String,
        owner: String
    ) async -> ClaudeResult? {
        guard let token = executionGate.tryAcquire(owner: owner) else {
            lastHint = busyHint
            return nil
        }
        defer { executionGate.release(token) }
        if lastHint == busyHint { lastHint = nil }
        return await claude(prompt, workingDirectory)
    }

    private func delegationBody(for task: MustardTask) -> String {
        task.notes.isEmpty ? task.title : "\(task.title)\n\n\(task.notes)"
    }
}
