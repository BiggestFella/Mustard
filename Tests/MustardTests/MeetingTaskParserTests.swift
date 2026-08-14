import XCTest
@testable import MustardKit

final class MeetingTaskParserTests: XCTestCase {
    // Pin UTC: due dates parse to midnight UTC, deterministic regardless of zone.
    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func test_harvestsOnlyCodeHeroesTasksSection() {
        let note = """
        # Standup 2026-06-16

        ## Summary
        - [ ] this bullet is prose, not a task we harvest

        ## Code Heroes tasks
        - [ ] Email Kamil the SDK spec 📅 2026-06-20
        - [x] Book the venue ✅ 2026-06-15

        ## Follow-ups
        - [ ] someone else's job
        """
        let tasks = MeetingTaskParser.parse(note, notePath: "meetings/x.md")
        XCTAssertEqual(tasks.map(\.title), ["Email Kamil the SDK spec", "Book the venue"])
    }

    func test_ignoredLedgerLinesAreNotHarvested() {
        let note = """
        ## Code Heroes tasks
        - [ ] Keep this task
        - [ ] Do not bring this back <!-- mustard:ignored -->
        """

        XCTAssertEqual(
            MeetingTaskParser.parse(note, notePath: "meetings/x.md").map(\.title),
            ["Keep this task"]
        )
    }

    func test_ignoredMarkerDoesNotChangeOriginKey() {
        let open = "- [ ] Do not bring this back"
        let ignored = "- [ ] Do not bring this back <!-- mustard:ignored -->"

        XCTAssertEqual(
            MeetingTaskParser.originKey(notePath: "meetings/x.md", line: open),
            MeetingTaskParser.originKey(notePath: "meetings/x.md", line: ignored)
        )
    }

    func test_checkboxStates() {
        let note = """
        ## Code Heroes tasks
        - [ ] open one
        - [x] done lower
        - [X] done upper
        """
        XCTAssertEqual(MeetingTaskParser.parse(note, notePath: "m.md").map(\.isDone),
                       [false, true, true])
    }

    func test_parsesDueDate_andNilWhenAbsent() {
        let note = """
        ## Code Heroes tasks
        - [ ] With a due 📅 2026-06-20
        - [ ] No due here
        """
        let tasks = MeetingTaskParser.parse(note, notePath: "m.md")
        XCTAssertEqual(tasks[0].due, at("2026-06-20T00:00:00Z"))
        XCTAssertNil(tasks[1].due)
    }

    func test_blockId_strippedFromTitle_butKeptInRawLine() {
        let note = """
        ## Code Heroes tasks
        - [ ] Refactor the parser ^abc-123
        """
        let t = MeetingTaskParser.parse(note, notePath: "m.md")[0]
        XCTAssertEqual(t.title, "Refactor the parser")
        XCTAssertTrue(t.rawLine.contains("^abc-123"))
    }

    func test_priorityAndDoneEmoji_strippedFromTitle() {
        let note = """
        ## Code Heroes tasks
        - [x] Ship the build 🔼 📅 2026-06-20 ✅ 2026-06-18
        """
        XCTAssertEqual(MeetingTaskParser.parse(note, notePath: "m.md")[0].title, "Ship the build")
    }

    func test_headingTolerance_levelAndTrailingText() {
        let note = """
        ### Code Heroes tasks (Leon)
        - [ ] Do the thing
        """
        XCTAssertEqual(MeetingTaskParser.parse(note, notePath: "m.md").map(\.title), ["Do the thing"])
    }

    func test_noMatchingSection_returnsEmpty() {
        let note = "## Notes\n- [ ] nothing here\n- [x] nor here"
        XCTAssertTrue(MeetingTaskParser.parse(note, notePath: "m.md").isEmpty)
    }

    func test_originKey_stableAcrossTick() {
        // Same line open vs completed must hash identically so a tick doesn't
        // look like a brand-new task on the next sweep.
        let open = "- [ ] Email Kamil the SDK spec 📅 2026-06-20 ^task1"
        let done = "- [x] Email Kamil the SDK spec 📅 2026-06-20 ✅ 2026-06-17 ^task1"
        XCTAssertEqual(
            MeetingTaskParser.originKey(notePath: "meetings/sync.md", line: open),
            MeetingTaskParser.originKey(notePath: "meetings/sync.md", line: done))
    }

    func test_skillLine_titleIsActionClauseOnly() {
        let note = """
        ## Code Heroes tasks
        - [ ] Move credentials to production — desc: "Promote the traffic-controller and dangerous-goods-driver credentials.", owner: Code Heroes, due: 2026-07-15 #task #creds #ch — [T: "targeting production imminently"]
        """
        let t = MeetingTaskParser.parse(note, notePath: "DL/m.md")[0]
        XCTAssertEqual(t.title, "Move credentials to production")
        XCTAssertEqual(t.desc, "Promote the traffic-controller and dangerous-goods-driver credentials.")
        XCTAssertEqual(t.owner, "Code Heroes")
        XCTAssertEqual(t.dueText, "2026-07-15")
        XCTAssertEqual(t.due, at("2026-07-15T00:00:00Z"))
        XCTAssertEqual(t.tags, ["creds"])
        XCTAssertEqual(t.transcriptQuote, "targeting production imminently")
    }

    func test_dueTextForms_nonDateLeavesDueNil() {
        let note = """
        ## Code Heroes tasks
        - [ ] Progress the launch — owner: Code Heroes, due: not stated #task #ch — [T: "q"]
        - [ ] Ship it — owner: Code Heroes, due: imminent #task #ch — [T: "q2"]
        """
        let ts = MeetingTaskParser.parse(note, notePath: "DL/m.md")
        XCTAssertEqual(ts[0].dueText, "not stated"); XCTAssertNil(ts[0].due)
        XCTAssertEqual(ts[1].dueText, "imminent");   XCTAssertNil(ts[1].due)
    }

    func test_wikilinkStrippedFromTitle_andOwner() {
        let note = """
        ## Code Heroes tasks
        - [ ] Request [[Kamil]] to send the SDK spec — owner: [[Leon Creed-Baker]], due: not stated #task #ch — [T: "q"]
        """
        let t = MeetingTaskParser.parse(note, notePath: "DL/m.md")[0]
        XCTAssertEqual(t.title, "Request Kamil to send the SDK spec")
        XCTAssertEqual(t.owner, "Leon Creed-Baker")
    }

    func test_plainLine_noEmDash_backwardCompatible() {
        let note = """
        ## Code Heroes tasks
        - [ ] Email Kamil the SDK spec 📅 2026-06-20
        """
        let t = MeetingTaskParser.parse(note, notePath: "m.md")[0]
        XCTAssertEqual(t.title, "Email Kamil the SDK spec")
        XCTAssertEqual(t.due, at("2026-06-20T00:00:00Z"))
        XCTAssertNil(t.desc); XCTAssertNil(t.transcriptQuote); XCTAssertEqual(t.tags, [])
    }

    /// Task Ledger lines carry `src:` — the meeting that raised the task. It must
    /// not leak into the title, and the trailing `^t-` id stays hidden as usual.
    func test_srcNote_parsedAndStrippedFromTitle() {
        let note = """
        ## Code Heroes tasks
        - [ ] Reply to TMR on the delete wording — desc: "Blocked on Leon.", owner: [[Leon Creed-Baker]], due: not stated, src: [[2026-07-16-dla-defect-review]] #task #app-store #ch — [T: "waiting on you"] ^t-20260716-delete-wording
        """
        let t = MeetingTaskParser.parse(note, notePath: "DL/meetings/Task Ledger.md")[0]
        XCTAssertEqual(t.title, "Reply to TMR on the delete wording")
        XCTAssertEqual(t.srcNote, "2026-07-16-dla-defect-review")
        XCTAssertEqual(t.owner, "Leon Creed-Baker")
        XCTAssertEqual(t.tags, ["app-store"])
        XCTAssertEqual(t.desc, "Blocked on Leon.")
    }

    func test_srcNote_nilWhenAbsent() {
        let note = """
        ## Code Heroes tasks
        - [ ] Email Kamil the SDK spec
        """
        XCTAssertNil(MeetingTaskParser.parse(note, notePath: "m.md")[0].srcNote)
    }

    func test_originKey_differsByNoteAndByLine() {
        let line = "- [ ] Same text"
        XCTAssertNotEqual(
            MeetingTaskParser.originKey(notePath: "a.md", line: line),
            MeetingTaskParser.originKey(notePath: "b.md", line: line))
        XCTAssertNotEqual(
            MeetingTaskParser.originKey(notePath: "a.md", line: "- [ ] One"),
            MeetingTaskParser.originKey(notePath: "a.md", line: "- [ ] Two"))
    }
}
