import XCTest
@testable import MustardKit

/// Before writing a rewrite back, the coordinator re-asserts the range it
/// snapshotted rather than trusting the target application to have preserved
/// its selection while the card held key focus. Whether an app keeps its
/// selection highlight after losing key-window status is app-specific; this
/// removes the question from the correctness path entirely.
///
/// `@MainActor` because the restorer's AX seams are main-actor-isolated: an AX
/// range write can be serviced in-process and reaches HIToolbox, which asserts
/// the main queue.
@MainActor
final class SelectionRestorerTests: XCTestCase {

    private func target(range: NSRange?) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "e", selectedRange: range,
            precedingCharacter: nil, followingCharacter: nil, isSecure: false)
    }

    func test_reasserts_theSnapshottedRange_whenIdentityStillMatches() {
        var written: NSRange?
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, range in written = range; return true })

        let outcome = restorer.reassert(on: target(range: NSRange(location: 4, length: 12)))

        XCTAssertEqual(outcome, .reasserted)
        XCTAssertEqual(written, NSRange(location: 4, length: 12))
    }

    func test_refuses_whenFocusMoved() {
        var written: NSRange?
        let restorer = SelectionRestorer(
            stillFocused: { _ in false },
            setSelectedRange: { _, range in written = range; return true })

        XCTAssertEqual(restorer.reassert(on: target(range: NSRange(location: 0, length: 3))),
                       .focusChanged)
        XCTAssertNil(written, "Nothing may be written into an element that no longer has focus.")
    }

    func test_withholdRange_isNotAFailure_becausePasteReplacesTheLiveSelection() {
        // Web areas hide their range. There is nothing to re-assert, and ⌘V
        // over whatever is selected still does the right thing — so this
        // proceeds rather than refusing and losing Gmail and Slack.
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, _ in XCTFail("nothing to set"); return false })

        XCTAssertEqual(restorer.reassert(on: target(range: nil)), .noRangeToReassert)
    }

    func test_aRejectedRangeWrite_isNotFatal() {
        // Plenty of apps refuse a settable range write yet still paste
        // correctly. Report it so it is logged, but do not block the write.
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, _ in false })

        XCTAssertEqual(restorer.reassert(on: target(range: NSRange(location: 1, length: 2))),
                       .reassertRejected)
    }

    func test_onlyFocusChanged_blocksTheWrite() {
        XCTAssertFalse(SelectionRestorer.Outcome.focusChanged.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.reasserted.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.noRangeToReassert.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.reassertRejected.permitsWrite)
    }
}
