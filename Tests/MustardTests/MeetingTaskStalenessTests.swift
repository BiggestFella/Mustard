import XCTest
import SwiftData
@testable import MustardKit

/// The 2026-08-14 import gate + identity migration, end to end through
/// `MeetingTaskSync`. Time is pinned to a fixed UTC instant throughout.
@MainActor
final class MeetingTaskStalenessTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self,
            Recommendation.self, AgentRun.self, AgentMessage.self, CalendarEvent.self,
            configurations: config)
        return ModelContext(container)
    }

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    private let now = "2026-08-14T00:00:00Z"

    private func note(_ tasks: String, title: String = "Standup") -> String {
        "# \(title)\n\n## Code Heroes tasks\n\(tasks)\n"
    }

    private func tasks(_ ctx: ModelContext) throws -> [MustardTask] {
        try ctx.fetch(FetchDescriptor<MustardTask>())
    }

    // MARK: the gate

    func test_staleMeetingIsBornArchived_neverShownNeverRun() throws {
        let ctx = try makeContext()
        // One of the real 2026-08-13 offenders: a May standup harvested in August.
        let io = FakeVaultIO([
            "DL/meetings/2026/05/2026-05-18-standup.md":
                note("- [ ] Run existing accessibility tickets through refinement")
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        let digest = sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].owner, .me, "a 12-week-old item must not be agent-owned")
        XCTAssertEqual(all[0].stage, .done, "it must not enter the approval queue or the Inbox")
        XCTAssertEqual(all[0].source, "meeting:archived")
        XCTAssertNotNil(all[0].originKey, "still keyed, so the line cannot re-import")
        XCTAssertEqual(digest.imported, 1)
        XCTAssertEqual(digest.archivedAsStale, 1)
    }

    func test_staleTombstoneIsNotWrittenBackToTheVault() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/05/2026-05-18-standup.md"
        let io = FakeVaultIO([path: note("- [ ] Run accessibility tickets through refinement")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        let digest = sync.importTasks(now: at(now))

        // Born done, but the ledger line must stay untouched: write-back is gated
        // on the exact `meeting` source, and Leon never made this decision.
        XCTAssertEqual(digest.syncedToVault, 0)
        XCTAssertTrue(io.files[path]!.contains("- [ ] Run accessibility tickets"))
        XCTAssertTrue(io.snapshots.isEmpty)
    }

    func test_freshMeetingStillReachesTheApprovalQueue() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL/meetings/2026/08/2026-08-12-standup.md":
                note("- [ ] Trigger the DexGuard fix build")
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        let digest = sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all[0].owner, .me)
        XCTAssertEqual(all[0].stage, .needsApproval)
        XCTAssertEqual(digest.archivedAsStale, 0)
    }

    func test_gatePrefersTheSrcMeetingDateOverTheLedgerPath() throws {
        let ctx = try makeContext()
        // A Task Ledger written today, holding a line raised in a May meeting.
        let io = FakeVaultIO([
            "DL/meetings/2026/08/2026-08-14-task-ledger.md":
                note("- [ ] Send team comms about the T22s assignments — src: [[2026-05-18-standup]]")
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all[0].owner, .me, "the meeting's date governs, not the ledger's")
        XCTAssertEqual(all[0].stage, .done)
        XCTAssertEqual(all[0].source, "meeting:archived")
    }

    func test_staleButAlreadyTickedStillImportsAsDone() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO([
            "DL/meetings/2026/05/2026-05-18-standup.md":
                note("- [ ] Old finished thing ✅ 2026-05-19".replacingOccurrences(of: "[ ]", with: "[x]"))
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        sync.importTasks(now: at(now))

        XCTAssertEqual(try tasks(ctx)[0].stage, .done)
    }

    func test_undatedNoteFailsOpenAndStaysActionable() throws {
        let ctx = try makeContext()
        let io = FakeVaultIO(["DL/meetings/inbox.md": note("- [ ] Something with no date anywhere")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        sync.importTasks(now: at(now))

        XCTAssertEqual(try tasks(ctx)[0].stage, .needsApproval,
                       "never silently downgrade work we cannot date")
    }

    // MARK: the ghost loop, end to end

    func test_agentClosureAnnotationDoesNotSpawnASecondTask() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let open = "- [ ] Trigger the DexGuard fix build — owner: Leon #task #ch"
        let io = FakeVaultIO([path: note(open)])
        let sync = MeetingTaskSync(context: ctx, io: io)
        sync.importTasks(now: at(now))
        XCTAssertEqual(try tasks(ctx).count, 1)

        // The agent finishes, ticks the line and writes its resolution into it —
        // the exact edit that minted 58 ghost tasks overnight on 2026-08-13→14.
        io.files[path] = note(
            "- [x] Trigger the DexGuard fix build — owner: Leon #task #ch ✅ 2026-08-13 "
            + "— **Closed — the build ran and shipped.** Evidence: `_agent/drafts/x.md`.")
        sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all.count, 1, "the same ledger line must remain one task")
        XCTAssertEqual(all[0].stage, .done, "the vault tick should close it, not clone it")
    }

    func test_dreamWikilinkPassDoesNotSpawnASecondTask() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let io = FakeVaultIO([path: note("- [ ] Chat with Graham about group-messaging testing")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        sync.importTasks(now: at(now))

        // `dream` cross-links first mentions. Correct behaviour on its part.
        io.files[path] = note("- [ ] Chat with [[Graham Nichols|Graham]] about group-messaging testing")
        sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Chat with Graham about group-messaging testing")
    }

    func test_twoIdenticalLedgerLinesStayTwoTasks() throws {
        let ctx = try makeContext()
        let dup = "- [ ] Re-review the build once it goes through"
        let io = FakeVaultIO([
            "DL/meetings/2026/08/2026-08-12-standup.md": note("\(dup)\n\(dup)")
        ])
        let sync = MeetingTaskSync(context: ctx, io: io)

        sync.importTasks(now: at(now))

        XCTAssertEqual(try tasks(ctx).count, 2, "duplicates must not collapse into one")
    }

    // MARK: one-time identity migration

    func test_rowStoredUnderTheLegacyKeyIsAdoptedNotReimported() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let line = "- [ ] Produce the 3.21 prep build — owner: Leon"
        let io = FakeVaultIO([path: note(line)])

        // A row as it exists in the live store today: keyed by the old whole-line hash.
        let legacy = MustardTask(title: "Produce the 3.21 prep build", owner: .agent)
        legacy.source = "meeting"
        legacy.sourceURL = path
        legacy.originKey = MeetingTaskParser.legacyOriginKey(notePath: path, line: line)
        legacy.stage = .needsApproval
        ctx.insert(legacy)

        let sync = MeetingTaskSync(context: ctx, io: io)
        let digest = sync.importTasks(now: at(now))

        let all = try tasks(ctx)
        XCTAssertEqual(all.count, 1, "must migrate in place, not import a duplicate")
        XCTAssertEqual(
            all[0].originKey,
            MeetingTaskParser.originKey(notePath: path, line: line),
            "the stored key should be rewritten to the durable scheme")
        XCTAssertEqual(digest.imported, 0)
        XCTAssertEqual(digest.keysMigrated, 1)
    }

    func test_migrationIsIdempotent() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let io = FakeVaultIO([path: note("- [ ] Produce the 3.21 prep build")])
        let sync = MeetingTaskSync(context: ctx, io: io)

        sync.importTasks(now: at(now))
        let second = sync.importTasks(now: at(now))

        XCTAssertEqual(try tasks(ctx).count, 1)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.keysMigrated, 0)
    }

    func test_archivedLegacyRowStillSuppressesReimport() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/05/2026-05-18-standup.md"
        let line = "- [ ] Long-pruned backlog item"
        let io = FakeVaultIO([path: note(line)])

        let pruned = MustardTask(title: "Long-pruned backlog item", owner: .agent)
        pruned.source = "meeting:archived"
        pruned.sourceURL = path
        pruned.originKey = MeetingTaskParser.legacyOriginKey(notePath: path, line: line)
        pruned.markDone(now: at("2026-06-24T00:00:00Z"))
        ctx.insert(pruned)

        let sync = MeetingTaskSync(context: ctx, io: io)
        sync.importTasks(now: at(now))

        XCTAssertEqual(try tasks(ctx).count, 1, "a pruned line must not re-flood")
    }

    // MARK: write-back survives the new identity

    func test_completeInVaultStillTicksTheRightLine() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let io = FakeVaultIO([path: note("- [ ] First task\n- [ ] Second task")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        sync.importTasks(now: at(now))

        let second = try tasks(ctx).first { $0.title == "Second task" }!
        XCTAssertTrue(sync.completeInVault(second, now: at(now)))

        let out = io.files[path]!
        XCTAssertTrue(out.contains("- [ ] First task"), "the wrong line must stay untouched")
        XCTAssertTrue(out.contains("- [x] Second task ✅ 2026-08-14"))
    }

    func test_completeInVaultTicksTheNthDuplicate() throws {
        let ctx = try makeContext()
        let path = "DL/meetings/2026/08/2026-08-12-standup.md"
        let dup = "- [ ] Re-review the build once it goes through"
        let io = FakeVaultIO([path: note("\(dup)\n\(dup)")])
        let sync = MeetingTaskSync(context: ctx, io: io)
        sync.importTasks(now: at(now))

        // Close only the second occurrence.
        let all = try tasks(ctx).sorted { ($0.originKey ?? "") < ($1.originKey ?? "") }
        let target = all.first {
            $0.originKey == MeetingTaskParser.originKey(notePath: path, line: dup, occurrence: 1)
        }
        XCTAssertNotNil(target)
        XCTAssertTrue(sync.completeInVault(target!, now: at(now)))

        let lines = io.files[path]!.components(separatedBy: "\n").filter { $0.contains("Re-review") }
        XCTAssertEqual(lines.filter { $0.contains("[x]") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("[ ]") }.count, 1)
    }
}
