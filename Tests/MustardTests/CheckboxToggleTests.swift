import XCTest
@testable import MustardKit

final class CheckboxToggleTests: XCTestCase {

    func test_toggle_uncheckedToChecked_lengthPreserving() {
        let source = "- [ ] task"
        let ns = source as NSString
        let location = ns.range(of: "task").location
        let result = CheckboxToggle.toggled(source, at: location)
        XCTAssertEqual(result?.source, "- [x] task")
        XCTAssertEqual((result!.source as NSString).length, ns.length)
    }

    func test_toggle_checkedLowercaseToUnchecked() {
        let source = "- [x] task"
        let location = (source as NSString).range(of: "task").location
        let result = CheckboxToggle.toggled(source, at: location)
        XCTAssertEqual(result?.source, "- [ ] task")
    }

    func test_toggle_checkedUppercaseToUnchecked() {
        let source = "- [X] task"
        let location = (source as NSString).range(of: "task").location
        let result = CheckboxToggle.toggled(source, at: location)
        XCTAssertEqual(result?.source, "- [ ] task")
    }

    func test_toggle_multiLineDoc_flipsOnlySecondTodoLine() {
        let source = "- [ ] first\n- [ ] second\n"
        let ns = source as NSString
        let secondLocation = ns.range(of: "second").location
        let result = CheckboxToggle.toggled(source, at: secondLocation)
        XCTAssertEqual(result?.source, "- [ ] first\n- [x] second\n")
    }

    func test_toggle_nonTodoLine_paragraph_returnsNil() {
        let source = "just a paragraph"
        XCTAssertNil(CheckboxToggle.toggled(source, at: 3))
    }

    func test_toggle_nonTodoLine_plainBullet_returnsNil() {
        let source = "- plain bullet"
        let location = (source as NSString).range(of: "bullet").location
        XCTAssertNil(CheckboxToggle.toggled(source, at: location))
    }

    func test_toggle_nonTodoLine_heading_returnsNil() {
        let source = "# Heading"
        let location = (source as NSString).range(of: "Heading").location
        XCTAssertNil(CheckboxToggle.toggled(source, at: location))
    }

    func test_toggle_locationNegative_returnsNil() {
        let source = "- [ ] task"
        XCTAssertNil(CheckboxToggle.toggled(source, at: -1))
    }

    func test_toggle_locationBeyondLength_returnsNil() {
        let source = "- [ ] task"
        let ns = source as NSString
        XCTAssertNil(CheckboxToggle.toggled(source, at: ns.length + 1))
    }

    func test_toggle_selection_isCollapsedAndWithinBounds() {
        let source = "- [ ] task"
        let ns = source as NSString
        let location = ns.range(of: "task").location
        let result = CheckboxToggle.toggled(source, at: location)
        XCTAssertEqual(result?.selection.length, 0)
        let newLength = (result!.source as NSString).length
        XCTAssertGreaterThanOrEqual(result!.selection.location, 0)
        XCTAssertLessThanOrEqual(result!.selection.location, newLength)
    }

    func test_toggle_roundTrip_isIdempotent() {
        let source = "- [ ] task"
        let ns = source as NSString
        let location = ns.range(of: "task").location
        let once = CheckboxToggle.toggled(source, at: location)
        XCTAssertNotNil(once)
        let twice = CheckboxToggle.toggled(once!.source, at: location)
        XCTAssertEqual(twice?.source, source)
    }
}
