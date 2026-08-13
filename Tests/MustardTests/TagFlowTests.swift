import XCTest
import CoreGraphics
@testable import MustardKit

final class TagFlowTests: XCTestCase {
    func testSingleRowWhenEverythingFits() {
        let rows = TagFlow.rows(itemWidths: [30, 40, 20], maxWidth: 200, spacing: 6)
        XCTAssertEqual(rows, [[0, 1, 2]])
    }

    func testWrapsToNextRowWhenTheRowIsFull() {
        // 60 + 6 + 60 = 126 fits; adding a third 60 would need 192 > 150.
        let rows = TagFlow.rows(itemWidths: [60, 60, 60], maxWidth: 150, spacing: 6)
        XCTAssertEqual(rows, [[0, 1], [2]])
    }

    func testItemWiderThanTheContainerGetsItsOwnRow() {
        // The long-tag case: never split a chip, never squeeze it — give it a row.
        let rows = TagFlow.rows(itemWidths: [40, 500, 40], maxWidth: 200, spacing: 6)
        XCTAssertEqual(rows, [[0], [1], [2]])
    }

    func testEmptyInput() {
        XCTAssertEqual(TagFlow.rows(itemWidths: [], maxWidth: 200, spacing: 6), [])
    }

    func testHeightSumsRowsAndSpacing() {
        let h = TagFlow.height(rowCount: 3, rowHeight: 20, spacing: 6)
        XCTAssertEqual(h, 72)  // 3*20 + 2*6
        XCTAssertEqual(TagFlow.height(rowCount: 0, rowHeight: 20, spacing: 6), 0)
    }
}
