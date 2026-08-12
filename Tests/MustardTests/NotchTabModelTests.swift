import XCTest
@testable import MustardKit

final class NotchTabModelTests: XCTestCase {
    func testFixedTabsInOrderThenCollections() {
        let tabs = NotchTabModel.tabs(collectionNames: ["Prompts", "Colors"])
        XCTAssertEqual(tabs, [
            .today, .agent, .meetings, .clips, .shelf,
            .collection(name: "Prompts"), .collection(name: "Colors"),
        ])
    }

    func testDefaultTabIsTodayUnlessRecording() {
        XCTAssertEqual(NotchTabModel.defaultTab(recordingActive: false), .today)
        XCTAssertEqual(NotchTabModel.defaultTab(recordingActive: true), .meetings)
    }

    func testHotkeyLandsOnClips() {
        XCTAssertEqual(NotchTabModel.clipsHotKeyTab, .clips)
    }

    func testTabTitles() {
        XCTAssertEqual(NotchTab.today.title, "Today")
        XCTAssertEqual(NotchTab.collection(name: "Prompts").title, "Prompts")
    }

    func testExpandedSizes() {
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .today), .init(width: 480, height: 500))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .agent), .init(width: 480, height: 500))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .meetings), .init(width: 480, height: 520))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .clips), .init(width: 480, height: 560))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .shelf), .init(width: 480, height: 560))
        XCTAssertEqual(
            NotchPanelMetrics.expandedSize(for: .collection(name: "x")),
            .init(width: 480, height: 560))
    }
}
