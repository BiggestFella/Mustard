import XCTest
@testable import MustardKit

/// The three-rung read ladder. The distinction that matters throughout:
/// "unreadable" is NOT "empty". Web areas withhold their value, and treating
/// a withheld value as an empty selection would rewrite nothing and call it
/// success.
final class SelectionLadderTests: XCTestCase {

    func test_rungOrder_isCheapestAndMostPassiveFirst() {
        XCTAssertEqual(SelectionRung.ordered,
                       [.axSelectedText, .axValueSubstring, .copyKeystroke],
                       "⌘C synthesis is last: it is the only rung that touches the target.")
    }

    func test_resolve_stopsAtTheFirstRungThatReturnsText() {
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .unreadable),
            (.axValueSubstring, .text("Can you send the SOW?")),
        ])
        XCTAssertEqual(resolved.read, .text("Can you send the SOW?"))
        XCTAssertEqual(resolved.rung, .axValueSubstring,
                       "The winning rung is recorded for the cross-app matrix.")
    }

    func test_resolve_treatsEmptyAsAuthoritative_andStops() {
        // A readable, genuinely empty selection is a real answer — do not
        // escalate to ⌘C and start synthesizing keystrokes over nothing.
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .empty),
            (.axValueSubstring, .text("should never be reached")),
        ])
        XCTAssertEqual(resolved.read, .empty)
        XCTAssertEqual(resolved.rung, .axSelectedText)
    }

    func test_resolve_isUnreadableOnlyWhenEveryRungWasUnreadable() {
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .unreadable),
            (.axValueSubstring, .unreadable),
            (.copyKeystroke, .unreadable),
        ])
        XCTAssertEqual(resolved.read, .unreadable)
        XCTAssertEqual(resolved.rung, .copyKeystroke, "The last rung attempted.")
    }

    func test_resolve_ofNoAttempts_isUnreadable() {
        XCTAssertEqual(SelectionLadder.resolve([]).read, .unreadable)
        XCTAssertNil(SelectionLadder.resolve([]).rung)
    }

    func test_shouldContinue_afterEachOutcome() {
        XCTAssertFalse(SelectionLadder.shouldContinue(after: .text("x")))
        XCTAssertFalse(SelectionLadder.shouldContinue(after: .empty))
        XCTAssertTrue(SelectionLadder.shouldContinue(after: .unreadable))
    }

    func test_substring_extractsTheSelectedRange_keepingEmojiWhole() {
        // UTF-16 offsets: "Ship the " is 8 units, the rocket is a surrogate
        // pair (2 units), so the emoji plus its flanking spaces is 8..<12.
        let value = "Ship the 🚀 launch on Thursday"
        let range = NSRange(location: 8, length: 4)
        XCTAssertEqual(SelectionLadder.substring(of: value, in: range), " 🚀 ")
    }

    func test_substring_ofARangeSplittingASurrogatePair_collapsesToEmpty() {
        // Half an emoji is not text. `Range(_:in:)` snaps to Character
        // boundaries, so a split pair comes back empty rather than as a
        // mangled replacement character — and empty is refused downstream by
        // `RewriteGate.accepts` as `.noSelection`. Never a corrupt rewrite.
        XCTAssertEqual(SelectionLadder.substring(of: "Ship the 🚀 launch",
                                                 in: NSRange(location: 9, length: 1)), "")
    }

    func test_substring_ofAnOutOfBoundsRange_isNil() {
        XCTAssertNil(SelectionLadder.substring(of: "short", in: NSRange(location: 40, length: 3)))
    }

    func test_substring_ofAZeroLengthRange_isEmptyNotNil() {
        XCTAssertEqual(SelectionLadder.substring(of: "abc", in: NSRange(location: 1, length: 0)), "")
    }
}
