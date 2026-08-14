import XCTest
import SwiftData
@testable import MustardKit

/// In-memory vault: a path→contents map that records writes + snapshots so the
/// write-back path can be asserted without touching disk.
final class FakeVaultIO: MeetingVaultIO {
    var files: [String: String]
    var rootPath: String = "/vault"
    private(set) var snapshots: [String: String] = [:]
    init(_ files: [String: String]) { self.files = files }

    func meetingNotePaths() -> [String] { files.keys.sorted() }
    func read(_ path: String) -> String? { files[path] }
    func write(_ path: String, _ contents: String) throws { files[path] = contents }
    func snapshot(_ path: String, _ contents: String) throws { snapshots[path] = contents }
}

@MainActor
final class MeetingTaskSyncTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self,
            Recommendation.self, AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func note(_ tasks: String) -> String {
        "# Weekly sync 2026-06-16\n\n## Code Heroes tasks\n\(tasks)\n"
    }

    private func tasks(_ ctx: ModelContext) throws -> [MustardTask] {
        try ctx.fetch(FetchDescriptor<MustardTask>())
    }

    func test_import_createsInboxTasks_withProvenance() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL/meetings/sync.md": note("- [ ] Email Kamil the SDK spec 📅 2026-06-20")
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        let digest = sync.importTasks()

        let all = try tasks(ctx)
        XCTAssertEqual(all.count, 1)
        let t = all[0]
        XCTAssertEqual(t.title, "Email Kamil the SDK spec")
        XCTAssertEqual(t.status, .inbox)
        // Imported meeting work waits for Leon's explicit decision. Approval later
        // moves it to `.queued`, which is the runnable agent lane.
        XCTAssertEqual(t.owner, .agent)
        XCTAssertEqual(t.stage, .needsApproval)
        XCTAssertEqual(t.source, "meeting")
        XCTAssertEqual(t.sourceURL, "DL/meetings/sync.md")
        XCTAssertEqual(t.dueAt, at("2026-06-20T00:00:00Z"))
        XCTAssertNotNil(t.originKey)
        XCTAssertEqual(digest.imported, 1)
    }

    func test_ignoreInVault_marksOnlyMatchingLineAndPreventsReimport() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/Task Ledger.md"
        let before = note("- [ ] Keep this task\n- [ ] Ignore this task")
        let io = FakeVaultIO([path: before])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()
        let ignored = try XCTUnwrap(try tasks(ctx).first { $0.title == "Ignore this task" })

        XCTAssertTrue(sync.ignoreInVault(ignored))
        XCTAssertEqual(io.snapshots[path], before)
        let after = try XCTUnwrap(io.files[path])
        XCTAssertTrue(after.contains("- [ ] Ignore this task <!-- mustard:ignored -->"))
        XCTAssertTrue(after.contains("- [ ] Keep this task"))
        XCTAssertFalse(after.contains("- [ ] Keep this task <!-- mustard:ignored -->"))
        XCTAssertEqual(sync.importTasks().imported, 0)
    }

    func test_import_reholdsLegacyRunnableMeetingTaskUntilApproved() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/Task Ledger.md": note("- [ ] Legacy task")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()
        let task = try XCTUnwrap(try tasks(ctx).first)
        task.stage = .forAgent
        task.agentApprovalGranted = false

        _ = sync.importTasks()

        XCTAssertEqual(task.stage, .needsApproval)

        task.agentApprovalGranted = true
        task.stage = .queued
        _ = sync.importTasks()
        XCTAssertEqual(task.stage, .queued)
    }

    func test_import_isIdempotent_dedupByOriginKey() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/sync.md": note("- [ ] Do the thing")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()
        let second = sync.importTasks()

        XCTAssertEqual(try tasks(ctx).count, 1)
        XCTAssertEqual(second.imported, 0)
    }

    func test_archivedMeetingTask_notReimported_andNotWrittenBack() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/old-sync.md"
        let io = FakeVaultIO([path: note("- [ ] Old team task")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        XCTAssertEqual(sync.importTasks().imported, 1)

        // The one-time backlog prune marks the task done and retags its source.
        let t = try XCTUnwrap(try tasks(ctx).first { $0.source == "meeting" })
        t.markDone()
        t.source = "meeting:archived"
        let beforeReimport = io.files[path]

        let again = sync.importTasks()

        XCTAssertEqual(again.imported, 0, "sentinel must still dedupe — no re-flood")
        XCTAssertEqual(try tasks(ctx).count, 1, "no duplicate created")
        XCTAssertEqual(io.files[path], beforeReimport, "archived task must not write ✅ back to the vault")
    }

    func test_import_assignsAreaByVaultRoot() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL/meetings/a.md": note("- [ ] DL task"),
            "Sandvik/meetings/b.md": note("- [ ] Sandvik task"),
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let byTitle = Dictionary(uniqueKeysWithValues: try tasks(ctx).map { ($0.title, $0) })
        XCTAssertEqual(byTitle["DL task"]?.list?.area?.name, "Digital Licence")
        XCTAssertEqual(byTitle["Sandvik task"]?.list?.area?.name, "Sandvik")
        // Areas are created once and reused.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Area>()).count, 2)
    }

    /// Regression: the real vault root is `Codeheroes work`, whose children are the
    /// `*-Knowledge-Base` directories — not the short codes the test above uses.
    /// Every task used to fall through to the Code Heroes fallback.
    func test_import_assignsArea_forRealKnowledgeBaseDirNames() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL-Knowledge-Base/meetings/Task Ledger.md": note("- [ ] DL ledger task"),
            "SB-Knowledge-Base/meetings/2026/07/x.md": note("- [ ] SB task"),
            "Sandvik-Knowledge-Base/meetings/2026/07/y.md": note("- [ ] Sandvik task"),
            "Code-Heroes-Knowledge-Base/meetings/2026/07/z.md": note("- [ ] CH task"),
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let byTitle = Dictionary(uniqueKeysWithValues: try tasks(ctx).map { ($0.title, $0) })
        XCTAssertEqual(byTitle["DL ledger task"]?.list?.area?.name, "Digital Licence")
        XCTAssertEqual(byTitle["SB task"]?.list?.area?.name, "Sales Buddi")
        XCTAssertEqual(byTitle["Sandvik task"]?.list?.area?.name, "Sandvik")
        XCTAssertEqual(byTitle["CH task"]?.list?.area?.name, "Code Heroes")
    }

    func test_import_alreadyCheckedLine_importedAsDone_notResurrected() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/a.md": note("- [x] Already finished ✅ 2026-06-15")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let t = try XCTUnwrap(try tasks(ctx).first)
        XCTAssertEqual(t.status, .done)
    }

    func test_import_vaultWonTheRace_completesOpenTask() throws {
        let ctx = try makeContext()
        let open = note("- [ ] Ship it")
        let io = FakeVaultIO(["DL/meetings/a.md": open])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()
        XCTAssertEqual(try tasks(ctx).first?.status, .inbox)

        // The line gets ticked in the vault out-of-band; next sweep should complete it.
        io.files["DL/meetings/a.md"] = note("- [x] Ship it ✅ 2026-06-17")
        let digest = sync.importTasks()

        XCTAssertEqual(try tasks(ctx).count, 1)
        XCTAssertEqual(try tasks(ctx).first?.status, .done)
        XCTAssertEqual(digest.completedFromVault, 1)
    }

    func test_import_writesBackTasksCompletedInMustard() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/a.md": note("- [ ] Finish me")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()
        let t = try XCTUnwrap(try tasks(ctx).first)
        t.markDone(now: at("2026-06-18T09:00:00Z"))  // completed in Mustard

        let digest = sync.importTasks()  // next sweep reconciles back to the vault

        XCTAssertEqual(digest.syncedToVault, 1)
        XCTAssertTrue(try XCTUnwrap(io.files["DL/meetings/a.md"]).contains("- [x] Finish me ✅ 2026-06-18"))
        // Reconciled — a further sweep is a no-op (no duplicate, no re-tick).
        XCTAssertEqual(sync.importTasks().syncedToVault, 0)
    }

    func test_writeBack_snapshotsThenTicksOnlyMatchedLine() throws {
        let ctx = try makeContext()
        let body = note("- [ ] First task\n- [ ] Second task")
        let io = FakeVaultIO(["DL/meetings/a.md": body])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()
        let first = try XCTUnwrap(try tasks(ctx).first { $0.title == "First task" })

        let ok = sync.completeInVault(first, now: at("2026-06-18T09:00:00Z"))

        XCTAssertTrue(ok)
        // Snapshot taken before the edit, holding the pre-edit contents.
        XCTAssertEqual(io.snapshots["DL/meetings/a.md"], body)
        let updated = try XCTUnwrap(io.files["DL/meetings/a.md"])
        XCTAssertTrue(updated.contains("- [x] First task ✅ 2026-06-18"))
        XCTAssertTrue(updated.contains("- [ ] Second task"))  // untouched
    }

    func test_writeBack_unmatchedLine_skipsAndFlags() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/a.md": note("- [ ] Original task")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()
        let t = try XCTUnwrap(try tasks(ctx).first)

        // Note edited out from under us — the line no longer exists.
        io.files["DL/meetings/a.md"] = note("- [ ] A completely different line")
        let ok = sync.completeInVault(t, now: at("2026-06-18T09:00:00Z"))

        XCTAssertFalse(ok)
        XCTAssertNil(io.snapshots["DL/meetings/a.md"])  // no snapshot, no write
        XCTAssertEqual(io.files["DL/meetings/a.md"], note("- [ ] A completely different line"))
    }

    func test_composeNotes_descMeetingOwnerDue() {
        let p = ParsedMeetingTask(
            title: "Move credentials to production", isDone: false,
            due: nil, desc: "Promote the creds to prod.", owner: "Code Heroes",
            dueText: "imminent", transcriptQuote: "targeting production imminently",
            tags: ["creds"], rawLine: "-", notePath: "DL/meetings/2026/04/2026-04-17-x.md",
            originKey: "k", srcNote: nil)
        let notes = MeetingTaskSync.composeNotes(p, subtitle: "DLA/DLV Feature Showcase")
        XCTAssertEqual(notes, """
        Promote the creds to prod.

        From: DLA/DLV Feature Showcase (2026-04-17)
        Context: "targeting production imminently"
        Owner: Code Heroes · Due: imminent
        """)
    }

    /// Tasks imported while the area map was broken all sat in the Code Heroes
    /// fallback. Left alone they would route into the wrong vault once a Code Heroes
    /// source exists, so a re-import repairs them.
    func test_import_repairsLegacyFallbackArea() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL-Knowledge-Base/meetings/2026/07/a.md": note("- [ ] DL thing")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()

        // Simulate the pre-fix state: correct task, wrong (fallback) area.
        let task = try XCTUnwrap(tasks(ctx).first)
        task.list = TaskList(name: "Code Heroes", area: Area(name: "Code Heroes"))

        let digest = sync.importTasks()

        XCTAssertEqual(task.list?.area?.name, "Digital Licence")
        XCTAssertEqual(digest.areasRepaired, 1)
        // Idempotent — a second pass finds nothing left to repair.
        XCTAssertEqual(sync.importTasks().areasRepaired, 0)
    }

    /// A task deliberately filed into a real (non-fallback) area must not be moved.
    func test_import_doesNotClobberDeliberateArea() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL-Knowledge-Base/meetings/2026/07/a.md": note("- [ ] DL thing")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()

        let task = try XCTUnwrap(tasks(ctx).first)
        task.list = TaskList(name: "Sandvik", area: Area(name: "Sandvik"))

        let digest = sync.importTasks()

        XCTAssertEqual(task.list?.area?.name, "Sandvik")
        XCTAssertEqual(digest.areasRepaired, 0)
    }

    /// The agent needs a real file to read — a ledger line's one-sentence desc is
    /// not enough. `src:` resolves to the curated note beside the ledger.
    func test_import_ledgerTask_carriesMeetingNotePathAndTitle() throws {
        let ctx = try makeContext()
        let ledger = """
        # Task Ledger

        ## Code Heroes tasks
        - [ ] Reply to TMR on the delete wording — desc: "Blocked on Leon.", src: [[2026-07-16-dla-defect-review]] #task #ch
        """
        let io = FakeVaultIO([
            "DL-Knowledge-Base/meetings/Task Ledger.md": ledger,
            "DL-Knowledge-Base/meetings/2026/07/2026-07-16-dla-defect-review.md":
                "# DLA Defect Review\n\nDecisions here.",
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let task = try XCTUnwrap(tasks(ctx).first { $0.title == "Reply to TMR on the delete wording" })
        // Absolute — the agent's cwd is a single vault, not the harvest root, so a
        // root-relative path would resolve to <vault>/DL-Knowledge-Base/... and miss.
        XCTAssertTrue(
            task.notes.contains("Meeting note: /vault/DL-Knowledge-Base/meetings/2026/07/2026-07-16-dla-defect-review.md"),
            "agent prompt must carry an absolute path to the meeting note; got:\n\(task.notes)")
        // Real meeting title, not the ledger's "Task Ledger" heading.
        XCTAssertEqual(task.sourceContext, "DLA Defect Review")
        // Write-back target must remain the ledger, or completions stop ticking.
        XCTAssertEqual(task.sourceURL, "DL-Knowledge-Base/meetings/Task Ledger.md")
    }

    /// A `src:` naming a note that isn't on disk must degrade, not emit a dead path.
    func test_import_unresolvableSrc_omitsMeetingNoteLine() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL-Knowledge-Base/meetings/Task Ledger.md": """
            # Task Ledger

            ## Code Heroes tasks
            - [ ] Do a thing — desc: "x", src: [[2026-07-16-does-not-exist]] #task #ch
            """,
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let task = try XCTUnwrap(tasks(ctx).first)
        XCTAssertFalse(task.notes.contains("Meeting note:"))
        XCTAssertEqual(task.sourceContext, "Task Ledger")
    }

    /// Ledger lines all share one path/title, so `src:` is the only provenance.
    func test_composeNotes_prefersSrcNoteOverLedgerSubtitle() {
        let p = ParsedMeetingTask(
            title: "Reply to TMR on the delete wording", isDone: false,
            due: nil, desc: "TMR is blocked on the answer.", owner: nil,
            dueText: nil, transcriptQuote: nil, tags: ["app-store"],
            rawLine: "-", notePath: "DL/meetings/Task Ledger.md",
            originKey: "k", srcNote: "2026-07-16-dla-defect-review-release-planning")
        let notes = MeetingTaskSync.composeNotes(p, subtitle: "Task Ledger")
        XCTAssertEqual(notes, """
        TMR is blocked on the answer.

        From: 2026-07-16-dla-defect-review-release-planning
        """)
    }

    func test_composeNotes_fallsBackToQuoteWhenNoDesc() {
        let p = ParsedMeetingTask(
            title: "Ship it", isDone: false, due: nil, desc: nil, owner: nil,
            dueText: nil, transcriptQuote: "we will ship", tags: [],
            rawLine: "-", notePath: "DL/m.md", originKey: "k", srcNote: nil)
        let notes = MeetingTaskSync.composeNotes(p, subtitle: "Standup")
        XCTAssertEqual(notes, "we will ship\n\nFrom: Standup")
    }

    func test_import_populatesNotesAndTags() throws {
        let ctx = try makeContext()
        let line = "- [ ] Email Kamil — desc: \"Send the SDK spec to Kamil.\", owner: [[Leon Creed-Baker]], due: 2026-07-15 #task #sdk #ch — [T: \"send Kamil the spec\"]"
        let io = FakeVaultIO(["DL/meetings/2026/06/2026-06-16-sync.md": note(line)])
        let sync = MeetingTaskSync(context: ctx, io: io)

        _ = sync.importTasks()

        let t = try XCTUnwrap(try tasks(ctx).first)
        XCTAssertEqual(t.title, "Email Kamil")
        XCTAssertEqual(t.tags, ["sdk"])
        XCTAssertEqual(t.dueAt, at("2026-07-15T00:00:00Z"))
        XCTAssertTrue(t.notes.contains("Send the SDK spec to Kamil."))
        XCTAssertTrue(t.notes.contains("From: Weekly sync 2026-06-16"))
    }

    func test_import_healsLegacyGiantTitleTaskOnce() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/06/2026-06-16-sync.md"
        let line = "- [ ] Email Kamil — desc: \"Send the SDK spec to Kamil.\", owner: [[Leon Creed-Baker]], due: not stated #task #sdk #ch — [T: \"send Kamil the spec\"]"
        let io = FakeVaultIO([path: note(line)])
        let sync = MeetingTaskSync(context: ctx, io: io)

        // Seed a legacy task: giant title (the raw line), empty notes, same originKey.
        let legacy = MustardTask(title: line, owner: .me)
        legacy.source = "meeting"; legacy.sourceURL = path; legacy.notes = ""
        legacy.originKey = MeetingTaskParser.originKey(notePath: path, line: line)
        ctx.insert(legacy)

        _ = sync.importTasks()
        XCTAssertEqual(try tasks(ctx).count, 1, "healed in place, not duplicated")
        XCTAssertEqual(legacy.title, "Email Kamil")
        XCTAssertTrue(legacy.notes.contains("Send the SDK spec to Kamil."))
        XCTAssertEqual(legacy.tags, ["sdk"])

        // Idempotent: a manual notes edit survives a second sweep.
        legacy.notes = "manually edited"
        _ = sync.importTasks()
        XCTAssertEqual(legacy.notes, "manually edited")
    }

    func test_writeBack_preservesBlockId() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/a.md": note("- [ ] Task with id ^xy7")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        _ = sync.importTasks()
        let t = try XCTUnwrap(try tasks(ctx).first)

        _ = sync.completeInVault(t, now: at("2026-06-18T09:00:00Z"))

        let updated = try XCTUnwrap(io.files["DL/meetings/a.md"])
        XCTAssertTrue(updated.contains("- [x] Task with id ✅ 2026-06-18 ^xy7"))
    }
}
