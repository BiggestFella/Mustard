import XCTest
@testable import MustardKit

final class GmailSyncPlannerTests: XCTestCase {
    func testNewIDsFiltersSeenKeepsOrderAndCaps() {
        let ids = GmailSyncPlanner.newIDs(listed: ["m5", "m4", "m3", "m2", "m1"],
                                          seen: ["m4", "m1"], limit: 2)
        XCTAssertEqual(ids, ["m5", "m3"])
    }

    func testNewIDsEmptyWhenAllSeen() {
        XCTAssertEqual(GmailSyncPlanner.newIDs(listed: ["a"], seen: ["a"], limit: 10), [])
    }

    func testUpdatedSeenAppendsAndCapsKeepingMostRecent() {
        let seen = GmailSyncPlanner.updatedSeen(["a", "b", "c"], adding: ["d", "e"], cap: 4)
        XCTAssertEqual(seen, ["b", "c", "d", "e"])
    }

    func testUpdatedSeenDeduplicatesReprocessedIDs() {
        XCTAssertEqual(GmailSyncPlanner.updatedSeen(["a", "b"], adding: ["b", "c"], cap: 10),
                       ["a", "b", "c"])
    }

    func testGiveUpIDsAfterCap() {
        var fails: [String: Int] = ["a": 2]
        let give = GmailSyncPlanner.registerFailures(&fails, ids: ["a", "b"], giveUpAt: 3)
        XCTAssertEqual(give, ["a"])          // a hits 3 → give up; b now at 1
        XCTAssertEqual(fails["b"], 1)
        XCTAssertNil(fails["a"])             // cleared once given up
    }

    func testRegisterFailuresBounded() {
        var fails: [String: Int] = [:]
        _ = GmailSyncPlanner.registerFailures(&fails, ids: (0..<10).map { "id\($0)" }, giveUpAt: 3, cap: 4)
        XCTAssertLessThanOrEqual(fails.count, 4)
    }
}
