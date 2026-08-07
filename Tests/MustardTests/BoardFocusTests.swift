import XCTest
@testable import MustardKit

/// Review-focus mode (BAK-101) collapses the board to exactly the gate columns.
final class BoardFocusTests: XCTestCase {
    func test_gateStages_areTheGates_inPipelineOrder() {
        XCTAssertEqual(PersonalBoard.gateStages, [.needsApproval, .needsInput, .needsReview])
    }

    // MARK: Auto-collapse empty columns (BAK-102)

    func test_shouldCollapseEmpty_everyoneEmptyNotExpanded_collapses() {
        XCTAssertTrue(PersonalBoard.shouldCollapseEmpty(view: .everyone, isEmpty: true, expanded: false, reviewFocus: false))
    }

    func test_shouldCollapseEmpty_nonEmpty_doesNot() {
        XCTAssertFalse(PersonalBoard.shouldCollapseEmpty(view: .everyone, isEmpty: false, expanded: false, reviewFocus: false))
    }

    func test_shouldCollapseEmpty_expanded_doesNot() {
        XCTAssertFalse(PersonalBoard.shouldCollapseEmpty(view: .everyone, isEmpty: true, expanded: true, reviewFocus: false))
    }

    func test_shouldCollapseEmpty_mineAndAgentLenses_doNot() {
        XCTAssertFalse(PersonalBoard.shouldCollapseEmpty(view: .mine, isEmpty: true, expanded: false, reviewFocus: false))
        XCTAssertFalse(PersonalBoard.shouldCollapseEmpty(view: .agent, isEmpty: true, expanded: false, reviewFocus: false))
    }

    func test_shouldCollapseEmpty_reviewFocus_doesNot() {
        XCTAssertFalse(PersonalBoard.shouldCollapseEmpty(view: .everyone, isEmpty: true, expanded: false, reviewFocus: true))
    }

    // MARK: Board search (BAK-134)

    func test_filterBySearch_emptyQuery_returnsAll() {
        let a = MustardTask(title: "Email Kamil")
        let b = MustardTask(title: "Draft notes")
        XCTAssertEqual(PersonalBoard.filterBySearch([a, b], query: "  ").count, 2)
    }

    func test_filterBySearch_matchesTitleCaseInsensitively() {
        let a = MustardTask(title: "Email Kamil")
        let b = MustardTask(title: "Draft notes")
        let r = PersonalBoard.filterBySearch([a, b], query: "kamil")
        XCTAssertEqual(r.map(\.title), ["Email Kamil"])
    }
}
