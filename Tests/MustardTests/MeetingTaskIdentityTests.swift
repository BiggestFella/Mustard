import XCTest
@testable import MustardKit

/// Regression suite for the ledger-line identity that produced the 2026-08-13
/// import flood. `originKey` used to hash the *whole* line, so any edit to it —
/// a `dream` pass adding `[[wikilinks]]`, or the agent appending its own closure
/// annotation — minted a new identity and the importer re-imported the same
/// action item as a fresh task. 693 rows arrived from 535 real ledger lines.
final class MeetingTaskIdentityTests: XCTestCase {
    private let note = "DL/meetings/2026/08/2026-08-13-standup.md"

    private func key(_ line: String, occurrence: Int = 0) -> String {
        MeetingTaskParser.originKey(notePath: note, line: line, occurrence: occurrence)
    }

    // MARK: the ghost loop

    func test_originKey_survivesTheAgentsOwnClosureAnnotation() {
        // The exact shape that spawned 58 ghosts overnight on 2026-08-13→14: the
        // agent ticks the line AND appends its resolution prose to it.
        let open = "- [ ] Trigger the DexGuard fix build — owner: Leon, due: 2026-08-13 #task #ch"
        let closed = "- [x] Trigger the DexGuard fix build — owner: Leon, due: 2026-08-13 #task #ch ✅ 2026-08-13 — **Closed — the build ran 13 Aug.** Evidence: `_agent/drafts/x.md`."
        XCTAssertEqual(key(open), key(closed))
    }

    func test_originKey_survivesADreamWikilinkPass() {
        // `dream`'s job is to add [[wikilinks]] on first mention. It must not
        // look like a new task afterwards.
        let before = "- [ ] Chat with Graham about group-messaging testing"
        let after = "- [ ] Chat with [[Graham Nichols|Graham]] about group-messaging testing"
        XCTAssertEqual(key(before), key(after))
    }

    func test_originKey_survivesMetadataFieldEdits() {
        // desc/owner/due are all after the em-dash and none of them is identity.
        let a = #"- [ ] Produce the 3.21 prep build — desc: "Cut PREP.", owner: Leon"#
        let b = #"- [ ] Produce the 3.21 prep build — desc: "Cut the PREP build for CDSB.", owner: [[Leon Creed-Baker]], due: 2026-08-20"#
        XCTAssertEqual(key(a), key(b))
    }

    func test_originKey_stableAcrossTickAndIgnoreMarker() {
        let open = "- [ ] Email Kamil the SDK spec 📅 2026-06-20"
        XCTAssertEqual(key(open), key("- [x] Email Kamil the SDK spec 📅 2026-06-20 ✅ 2026-06-17"))
        XCTAssertEqual(key(open), key("- [ ] Email Kamil the SDK spec 📅 2026-06-20 <!-- mustard:ignored -->"))
    }

    // MARK: identity still discriminates

    func test_originKey_differsByNoteAndByTitle() {
        let line = "- [ ] Same text"
        XCTAssertNotEqual(
            MeetingTaskParser.originKey(notePath: "a.md", line: line),
            MeetingTaskParser.originKey(notePath: "b.md", line: line))
        XCTAssertNotEqual(key("- [ ] One"), key("- [ ] Two"))
    }

    func test_originKey_changesWhenTheActionItselfIsRewritten() {
        // Editing what the task *is* should legitimately create a new task.
        XCTAssertNotEqual(
            key("- [ ] Deploy the front-end"),
            key("- [ ] Deploy the back-end"))
    }

    // MARK: duplicate titles in one note

    func test_originKey_duplicateTitlesInOneNoteGetDistinctKeys() {
        let line = "- [ ] Re-review the build once it goes through"
        XCTAssertNotEqual(key(line, occurrence: 0), key(line, occurrence: 1))
    }

    func test_parse_assignsOccurrenceOrdinalsSoDuplicatesBothSurvive() {
        let text = """
        ## Code Heroes tasks
        - [ ] Re-review the build once it goes through
        - [ ] Re-review the build once it goes through
        """
        let parsed = MeetingTaskParser.parse(text, notePath: note)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNotEqual(parsed[0].originKey, parsed[1].originKey,
                          "two real ledger lines must not collapse into one task")
    }

    // MARK: block id anchors identity when present

    func test_originKey_prefersBlockIDOverTitle() {
        // Only ~7% of ledger lines carry one, but where it exists it is the
        // durable anchor: the action text can be reworded and stay the same task.
        let a = "- [ ] Produce the 3.21 prep build ^task-3-21"
        let b = "- [x] Produce the 3.21.0 PREP build for CDSB ✅ 2026-08-13 ^task-3-21"
        XCTAssertEqual(key(a), key(b))
    }

    func test_originKey_differentBlockIDsAreDifferentTasks() {
        XCTAssertNotEqual(
            key("- [ ] Same title ^task-a"),
            key("- [ ] Same title ^task-b"))
    }

    // MARK: legacy key, for the one-time migration

    func test_legacyOriginKey_reproducesTheOldWholeLineHash() {
        // Frozen expectation: this is what pre-migration rows hold in the store,
        // so the value must not drift or existing tasks stop being recognised.
        let line = "- [ ] Email Kamil the SDK spec 📅 2026-06-20"
        XCTAssertEqual(
            MeetingTaskParser.legacyOriginKey(notePath: "meetings/sync.md", line: line),
            "c98958fedbcf4f0c51ffc8745705375ed599f9d67b55b20663d798fbaeb4f425")
    }

    func test_legacyOriginKey_isSensitiveToTheWholeLine() {
        // The old behaviour, kept only for lookup: annotation churn moved the key.
        XCTAssertNotEqual(
            MeetingTaskParser.legacyOriginKey(notePath: note, line: "- [ ] Do it"),
            MeetingTaskParser.legacyOriginKey(notePath: note, line: "- [ ] Do it — owner: Leon"))
    }

    // MARK: locating the line for write-back

    func test_lineIndex_findsTheMatchingLedgerLine() {
        let lines = [
            "## Code Heroes tasks",
            "- [ ] First task",
            "- [ ] Second task",
        ]
        XCTAssertEqual(
            MeetingTaskParser.lineIndex(ofKey: key("- [ ] Second task"), in: lines, notePath: note),
            2)
    }

    func test_lineIndex_respectsOccurrenceOrderForDuplicates() {
        let dup = "- [ ] Re-review the build once it goes through"
        let lines = ["## Code Heroes tasks", dup, dup]
        XCTAssertEqual(
            MeetingTaskParser.lineIndex(ofKey: key(dup, occurrence: 1), in: lines, notePath: note),
            2)
    }

    func test_lineIndex_nilWhenTheLineIsGone() {
        XCTAssertNil(MeetingTaskParser.lineIndex(
            ofKey: key("- [ ] Deleted task"),
            in: ["## Code Heroes tasks", "- [ ] Something else"],
            notePath: note))
    }

    // MARK: the [[A|B]] title bug (6 malformed cards on the board)

    func test_extractTitle_aliasedWikilinkKeepsTheDisplayHalf() {
        let text = """
        ## Code Heroes tasks
        - [ ] Ask [[Alex-Gouges|Alex]] to revisit DexGuard obfuscation depth
        """
        XCTAssertEqual(
            MeetingTaskParser.parse(text, notePath: note)[0].title,
            "Ask Alex to revisit DexGuard obfuscation depth")
    }

    func test_extractTitle_plainWikilinkIsUnwrapped() {
        let text = """
        ## Code Heroes tasks
        - [ ] Brief [[Comms]] on the external-link approach
        """
        XCTAssertEqual(
            MeetingTaskParser.parse(text, notePath: note)[0].title,
            "Brief Comms on the external-link approach")
    }

    func test_srcNote_keepsTheLinkTargetNotTheDisplayText() {
        // `src:` must resolve to a file on disk, so an aliased link keeps the
        // target half — the opposite of the title rule above.
        let text = """
        ## Code Heroes tasks
        - [ ] Do it — src: [[2026-05-18-standup|Monday's standup]]
        """
        XCTAssertEqual(
            MeetingTaskParser.parse(text, notePath: note)[0].srcNote,
            "2026-05-18-standup")
    }

    func test_parse_skipsLinesWithNoTitleLeft() {
        // A line that is only metadata yielded an empty-titled card in the store.
        let text = """
        ## Code Heroes tasks
        - [ ] — owner: Leon, due: 2026-08-13
        - [ ] Real task
        """
        XCTAssertEqual(
            MeetingTaskParser.parse(text, notePath: note).map(\.title),
            ["Real task"])
    }
}
