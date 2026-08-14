import XCTest
@testable import MustardKit

/// Time is pinned to a fixed UTC instant throughout — day boundaries in AEST
/// would otherwise flake the ±7-day cutoff (see CLAUDE.md testing rules).
final class MeetingTaskFreshnessTests: XCTestCase {
    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    private let now = "2026-08-14T00:00:00Z"

    // MARK: meetingDate resolution

    func test_meetingDate_prefersSrcNoteOverLedgerPath() {
        // A Task Ledger line lives in one undated (or differently dated) file but
        // names its originating meeting in `src:`. The meeting's date is the truth.
        let date = MeetingTaskFreshness.meetingDate(
            srcNote: "2026-05-18-standup-all-tickets",
            notePath: "DL/_agent/2026-08-13-task-ledger.md")
        XCTAssertEqual(date, at("2026-05-18T00:00:00Z"))
    }

    func test_meetingDate_fallsBackToNotePath() {
        let date = MeetingTaskFreshness.meetingDate(
            srcNote: nil, notePath: "DL/meetings/2026/05/2026-05-18-standup.md")
        XCTAssertEqual(date, at("2026-05-18T00:00:00Z"))
    }

    func test_meetingDate_nilWhenNeitherCarriesADate() {
        XCTAssertNil(MeetingTaskFreshness.meetingDate(
            srcNote: "untitled-sync", notePath: "DL/meetings/inbox.md"))
    }

    func test_meetingDate_ignoresADateInAParentDirectory() {
        // Only the file name is scanned: `meetings/2026/05/` would otherwise
        // resolve every note in the folder to the first path digits found.
        XCTAssertNil(MeetingTaskFreshness.meetingDate(
            srcNote: nil, notePath: "DL/meetings/2026/05/standup-no-date.md"))
    }

    // MARK: the 7-day gate

    func test_isFresh_recentMeetingIsFresh() {
        XCTAssertTrue(MeetingTaskFreshness.isFresh(
            srcNote: "2026-08-12-standup", notePath: "x.md", now: at(now)))
    }

    func test_isFresh_theBacklogThatFloodedTheBoardIsNotFresh() {
        // The 2026-08-13 import pulled 44 meetings dated Apr 15 – Jun 4.
        for slug in ["2026-04-15-ccms-integration", "2026-05-18-standup", "2026-06-04-ccms-checkin"] {
            XCTAssertFalse(
                MeetingTaskFreshness.isFresh(srcNote: slug, notePath: "x.md", now: at(now)),
                "\(slug) is 10+ weeks old and must not reach the agent")
        }
    }

    func test_isFresh_boundaryIsInclusiveAtExactlySevenDays() {
        // Exactly 7 days old still counts as fresh; 8 does not.
        XCTAssertTrue(MeetingTaskFreshness.isFresh(
            srcNote: "2026-08-07-standup", notePath: "x.md", now: at(now)))
        XCTAssertFalse(MeetingTaskFreshness.isFresh(
            srcNote: "2026-08-06-standup", notePath: "x.md", now: at(now)))
    }

    func test_isFresh_failsOpenWhenNoDateIsKnown() {
        // Never silently downgrade real work: an undated line stays actionable.
        XCTAssertTrue(MeetingTaskFreshness.isFresh(
            srcNote: nil, notePath: "DL/meetings/inbox.md", now: at(now)))
    }

    func test_isFresh_futureDatedMeetingIsFresh() {
        XCTAssertTrue(MeetingTaskFreshness.isFresh(
            srcNote: "2026-08-20-planning", notePath: "x.md", now: at(now)))
    }

    func test_isFresh_windowIsConfigurable() {
        XCTAssertTrue(MeetingTaskFreshness.isFresh(
            srcNote: "2026-07-20-standup", notePath: "x.md", now: at(now), withinDays: 30))
        XCTAssertFalse(MeetingTaskFreshness.isFresh(
            srcNote: "2026-07-20-standup", notePath: "x.md", now: at(now), withinDays: 7))
    }
}
