import XCTest
import SwiftData
@testable import MustardKit

private final class FakeNoteIO: NoteVaultIO {
    var files: [String: String]
    var mtimes: [String: Date] = [:]
    /// Fired on every read — lets TOCTOU tests simulate a writer racing the rebuild
    /// (mutate `mtimes` here to model a save landing between stat and read).
    var onRead: ((String) -> Void)?
    init(_ files: [String: String]) { self.files = files }
    func notePaths() -> [String] { files.keys.sorted() }
    func read(_ p: String) -> String? { onRead?(p); return files[p] }
    func write(_ p: String, _ c: String) throws { files[p] = c }
    func snapshot(_ p: String, _ c: String) throws {}
    func modificationDate(_ p: String) -> Date? { mtimes[p] }
    func move(from: String, to: String) throws { files[to] = files.removeValue(forKey: from); mtimes[to] = mtimes.removeValue(forKey: from) }
    func trash(_ p: String) throws { files.removeValue(forKey: p); mtimes.removeValue(forKey: p) }
}

@MainActor
final class NoteIndexServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, CalendarEvent.self, NoteIndexEntry.self,
            configurations: config))
    }
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Fresh in-memory defaults suite, pre-seeded with the given parser version.
    /// Tests must never touch `.standard`: the parser-version salt reads/writes it
    /// on init, which would make guard behavior order-dependent across test runs.
    private func makeDefaults(version: Int? = NoteIndexService.parserVersion) -> UserDefaults {
        let suite = "NoteIndexServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let version { defaults.set(version, forKey: "noteIndexParserVersion") }
        return defaults
    }

    private func makeService(_ ctx: ModelContext, io: FakeNoteIO,
                             defaults: UserDefaults? = nil) -> NoteIndexService {
        NoteIndexService(context: ctx, makeIO: { _ in io }, defaults: defaults ?? makeDefaults())
    }

    func test_reindex_buildsEntries_titleTagsLinksSnapshot() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO([
            "Home.md": "---\ntags: [hub]\n---\n# Home\ngo [[Setup]]",
            "guides/Setup.md": "# Setup",
        ])
        io.mtimes["Home.md"] = t0
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let entries = try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).sorted { $0.relativePath < $1.relativePath }
        XCTAssertEqual(entries.map(\.relativePath), ["Home.md", "guides/Setup.md"])
        XCTAssertEqual(entries[0].title, "Home")
        XCTAssertEqual(entries[0].tags, ["hub"])
        XCTAssertEqual(entries[0].forwardLinks, ["guides/Setup.md"])
        XCTAssertEqual(entries[0].lastModified, t0)
        XCTAssertEqual(entries[0].project, "KB")
        XCTAssertTrue(entries[0].contentSnapshot.contains("[[Setup]]"))
    }

    func test_reindex_isWholesale_removesDeletedFiles_leavesOtherProjects() throws {
        let ctx = try makeContext()
        ctx.insert(NoteIndexEntry(project: "KB", relativePath: "gone.md"))
        ctx.insert(NoteIndexEntry(project: "Other", relativePath: "keep.md"))
        let svc = makeService(ctx, io: FakeNoteIO(["new.md": "# N"]))
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let paths = try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).map { "\($0.project)/\($0.relativePath)" }.sorted()
        XCTAssertEqual(paths, ["KB/new.md", "Other/keep.md"])
    }

    func test_reindexDueProjects_respectsThrottle_andSkipsDisabled() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        let svc = makeService(ctx, io: io)
        let settings = SourceSettings(sources: [
            SourceConfig(id: .vault, project: "KB", enabled: true, workingDirectory: "/kb"),
            SourceConfig(id: .vault, project: "Off", enabled: false, workingDirectory: "/off"),
        ], state: [])
        svc.reindexDueProjects(settings, now: t0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).map(\.project), ["KB"])
        io.files["b.md"] = "# B"
        svc.reindexDueProjects(settings, now: t0.addingTimeInterval(60))    // throttled — no change
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).count, 1)
        svc.reindexDueProjects(settings, now: t0.addingTimeInterval(301))   // due again
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).count, 2)
    }

    // MARK: Change-guard (skip no-op rebuilds)

    func test_reindex_unchanged_skipsRebuild_entriesNotRecreated() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["Home.md": "# Home\n[[Setup]]", "Setup.md": "# Setup"])
        io.mtimes["Home.md"] = t0
        io.mtimes["Setup.md"] = t0
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let idsBefore = Set(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).map(\.persistentModelID))
        XCTAssertEqual(idsBefore.count, 2)

        // Nothing on disk changed → same PersistentIdentifiers survive (no delete+reinsert).
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        let idsAfter = Set(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).map(\.persistentModelID))
        XCTAssertEqual(idsAfter, idsBefore)
        // Throttle still advanced so the loop backs off.
        XCTAssertEqual(svc.lastIndexedAt["KB"], t0.addingTimeInterval(600))
    }

    func test_reindex_fileTouched_rebuilds() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["Home.md": "# Home"])
        io.mtimes["Home.md"] = t0
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let idBefore = try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID

        io.files["Home.md"] = "# Home renamed"
        io.mtimes["Home.md"] = t0.addingTimeInterval(60)   // touched
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        let entriesAfter = try ctx.fetch(FetchDescriptor<NoteIndexEntry>())
        XCTAssertEqual(entriesAfter.count, 1)
        XCTAssertEqual(entriesAfter[0].title, "Home renamed")
        XCTAssertNotEqual(entriesAfter.first?.persistentModelID, idBefore)  // deleted + reinserted
    }

    func test_reindex_fileAdded_rebuilds() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["Home.md": "# Home"])
        io.mtimes["Home.md"] = t0
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        io.files["New.md"] = "# New"
        io.mtimes["New.md"] = t0
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).count, 2)
    }

    func test_reindex_fileRemoved_rebuilds() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["Home.md": "# Home", "Gone.md": "# Gone"])
        io.mtimes["Home.md"] = t0
        io.mtimes["Gone.md"] = t0
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        io.files["Gone.md"] = nil
        io.mtimes["Gone.md"] = nil
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).map(\.relativePath), ["Home.md"])
    }

    // MARK: Force path (deep-review blocker 1)

    /// reindexAll is the manual ⌘K "Reindex notes now" — the user's explicit ask
    /// must always rebuild, even when the change-guard would call it a no-op.
    func test_reindexAll_forcesRebuild_evenWhenGuardWouldSkip() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        io.mtimes["a.md"] = t0
        let svc = makeService(ctx, io: io)
        let settings = SourceSettings(sources: [
            SourceConfig(id: .vault, project: "KB", enabled: true, workingDirectory: "/kb"),
        ], state: [])
        svc.reindexAll(settings, now: t0)
        let idBefore = try XCTUnwrap(ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID)

        // Paths + mtimes unchanged: the scheduled path would skip (test above), but
        // the manual path must rebuild anyway.
        svc.reindexAll(settings, now: t0.addingTimeInterval(600))
        let entries = try ctx.fetch(FetchDescriptor<NoteIndexEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotEqual(entries.first?.persistentModelID, idBefore)
    }

    // MARK: Parser-version salt (deep-review blocker 2)

    /// A shipped parser change (new title rule, CRLF fix) alters DERIVED rows
    /// without touching bytes on disk — mtimes still match, so the guard would skip
    /// forever and the fix would never reach already-indexed notes. A version
    /// mismatch must disable the guard for the whole session and persist the new
    /// version so the NEXT launch trusts the guard again.
    func test_parserVersionMismatch_disablesGuardForSession_andPersistsVersion() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        io.mtimes["a.md"] = t0
        let defaults = makeDefaults(version: NoteIndexService.parserVersion - 1)   // stale
        let svc = makeService(ctx, io: io, defaults: defaults)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let idBefore = try XCTUnwrap(ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID)

        // Same paths + mtimes, but the salt keeps the guard off all session → rebuild.
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        XCTAssertNotEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID, idBefore)

        // The new version was written immediately on init.
        XCTAssertEqual(defaults.integer(forKey: "noteIndexParserVersion"), NoteIndexService.parserVersion)

        // "Next launch": a fresh service on the SAME defaults trusts the guard again.
        let relaunched = makeService(ctx, io: io, defaults: defaults)
        relaunched.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(1200))
        let idStable = try XCTUnwrap(ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID)
        relaunched.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(1800))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID, idStable)
    }

    func test_parserVersionMatch_guardStillSkips() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        io.mtimes["a.md"] = t0
        let svc = makeService(ctx, io: io, defaults: makeDefaults())   // matching version
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)
        let idBefore = try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first?.persistentModelID, idBefore)
    }

    // MARK: Stat-before-read (deep-review blocker 3, TOCTOU)

    /// A write can land between the pre-pass stat and the content read. The stored
    /// lastModified must be the PRE-READ mtime: then disk ≠ stored on the next tick
    /// → rebuild (safe direction). Storing a post-read stat would stamp a newer
    /// mtime than the content actually read and skip the racing write forever.
    func test_reindex_storesPreReadMtime_soRacingWriteRebuildsNextTick() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        io.mtimes["a.md"] = t0
        let t1 = t0.addingTimeInterval(30)
        // Racing writer: the read triggers a save that bumps the mtime (once).
        io.onRead = { [weak io] _ in
            io?.mtimes["a.md"] = t1
            io?.files["a.md"] = "# A updated"
            io?.onRead = nil
        }
        let svc = makeService(ctx, io: io)
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0)

        // Stored mtime is the pre-read stat (t0), not the racing writer's t1.
        let entry = try XCTUnwrap(ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first)
        XCTAssertEqual(entry.lastModified, t0)
        let idBefore = entry.persistentModelID

        // Next tick: disk (t1) ≠ stored (t0) → the guard rebuilds (id changes) and
        // the row now carries the racing write's mtime.
        svc.reindex(project: "KB", workingDirectory: "/kb", now: t0.addingTimeInterval(600))
        let after = try XCTUnwrap(ctx.fetch(FetchDescriptor<NoteIndexEntry>()).first)
        XCTAssertNotEqual(after.persistentModelID, idBefore)
        XCTAssertEqual(after.lastModified, t1)
    }

    func test_reindexAll_bypassesThrottle() throws {
        let ctx = try makeContext()
        let io = FakeNoteIO(["a.md": "# A"])
        let svc = makeService(ctx, io: io)
        let settings = SourceSettings(sources: [
            SourceConfig(id: .vault, project: "KB", enabled: true, workingDirectory: "/kb"),
        ], state: [])
        svc.reindexDueProjects(settings, now: t0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).count, 1)
        io.files["b.md"] = "# B"
        // 60s later the throttle would block reindexDueProjects (see the test above),
        // but the manual ⌘K path ignores it.
        svc.reindexAll(settings, now: t0.addingTimeInterval(60))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NoteIndexEntry>()).count, 2)
    }
}
