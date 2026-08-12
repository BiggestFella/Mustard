import XCTest
@testable import MustardKit

final class NotchPinStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func t(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testStartsCollapsed() {
        let state = NotchPinState()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPinned)
    }

    func testHoverPeeksAndExitCollapsesAfterGrace() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        XCTAssertTrue(state.isExpanded)

        state.hoverChanged(isInside: false, now: t(1))
        // Still expanded during the grace window.
        XCTAssertTrue(state.isExpanded)
        XCTAssertFalse(state.shouldCollapse(now: t(1.1)))
        XCTAssertTrue(state.shouldCollapse(now: t(1.4)))

        state.collapseIfDue(now: t(1.4))
        XCTAssertFalse(state.isExpanded)
    }

    func testReenterDuringGraceCancelsCollapse() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.hoverChanged(isInside: false, now: t(1))
        state.hoverChanged(isInside: true, now: t(1.2))
        XCTAssertFalse(state.shouldCollapse(now: t(5)))
        XCTAssertTrue(state.isExpanded)
    }

    func testClickPinsAndHoverExitNoLongerCollapses() {
        var state = NotchPinState()
        state.pin()
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.isPinned)
        state.hoverChanged(isInside: false, now: t(1))
        XCTAssertFalse(state.shouldCollapse(now: t(10)))
        XCTAssertTrue(state.isExpanded)
    }

    func testUnpinCollapsesImmediately() {
        var state = NotchPinState()
        state.pin()
        state.unpin()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPinned)
    }

    func testUnpinWhileHoveringStaysPeeked() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.pin()
        state.unpin()
        XCTAssertTrue(state.isExpanded)   // pointer is still inside
        XCTAssertFalse(state.isPinned)
    }

    func testCollapseIfDueIsNoopWhilePinnedOrHovering() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.collapseIfDue(now: t(10))
        XCTAssertTrue(state.isExpanded)
    }
}
