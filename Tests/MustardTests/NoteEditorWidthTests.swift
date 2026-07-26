import XCTest
@testable import MustardKit

final class NoteEditorWidthTests: XCTestCase {
    func test_maxWidth_pins_point_values() {
        XCTAssertEqual(NoteEditorWidth.comfortable.maxWidth, 720)
        XCTAssertEqual(NoteEditorWidth.wide.maxWidth, 960)
        XCTAssertNil(NoteEditorWidth.full.maxWidth, "full is unconstrained (full-bleed)")
    }

    func test_allCases_and_labels() {
        XCTAssertEqual(NoteEditorWidth.allCases, [.comfortable, .wide, .full])
        XCTAssertEqual(NoteEditorWidth.wide.label, "Wide")
    }
}
