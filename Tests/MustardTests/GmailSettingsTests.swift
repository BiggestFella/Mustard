import XCTest
@testable import MustardKit

final class GmailSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "GmailSettingsTests")!
        defaults.removePersistentDomain(forName: "GmailSettingsTests")
    }

    func testDefaults() {
        let s = GmailSettingsStore.load(defaults)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.labelId, "INBOX")
        XCTAssertEqual(s.query, "newer_than:3d")
        XCTAssertEqual(s.pollIntervalMinutes, 5)
    }

    func testRoundTrip() {
        var s = GmailSettingsStore.load(defaults)
        s.enabled = true
        s.labelId = "Label_7"
        s.pollIntervalMinutes = 10
        GmailSettingsStore.save(s, to: defaults)
        XCTAssertEqual(GmailSettingsStore.load(defaults), s)
    }

    func testIsDue() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(GmailSettings.isDue(lastPolledAt: nil, intervalMinutes: 5, now: now))
        XCTAssertFalse(GmailSettings.isDue(lastPolledAt: now.addingTimeInterval(-299), intervalMinutes: 5, now: now))
        XCTAssertTrue(GmailSettings.isDue(lastPolledAt: now.addingTimeInterval(-300), intervalMinutes: 5, now: now))
        XCTAssertFalse(GmailSettings.isDue(lastPolledAt: nil, intervalMinutes: 0, now: now))
    }

    func testSyncStateRoundTripAndDefault() {
        XCTAssertEqual(GmailSyncStateStore.load(defaults), GmailSyncState())
        var state = GmailSyncState()
        state.seenEventIDs = ["m1", "m2"]
        state.lastPolledAt = Date(timeIntervalSince1970: 1_780_000_000)
        GmailSyncStateStore.save(state, to: defaults)
        XCTAssertEqual(GmailSyncStateStore.load(defaults), state)
    }
}
