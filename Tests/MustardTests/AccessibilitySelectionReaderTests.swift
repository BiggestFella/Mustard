import XCTest
@testable import MustardKit

/// The live reader's SEQUENCING, with all three rungs stubbed. No test here
/// touches AX or the pasteboard — the point is to pin that rung 3 (⌘C) is only
/// ever reached when the passive rungs came back unreadable.
final class AccessibilitySelectionReaderTests: XCTestCase {

    private let target = FocusedTextTarget(
        applicationPID: 501,
        elementIdentifier: "501#t#AXWebArea#Gmail",
        selectedRange: NSRange(location: 0, length: 5),
        precedingCharacter: nil,
        followingCharacter: nil,
        isSecure: false)

    private func reader(
        axSelectedText: @escaping () -> String? = { nil },
        axValue: @escaping () -> String? = { nil },
        copy: @escaping () -> String? = { nil },
        copyCount: CopyCounter = CopyCounter()
    ) -> AccessibilitySelectionReader {
        AccessibilitySelectionReader(
            readSelectedTextAttribute: { _ in axSelectedText() },
            readValueAttribute: { _ in axValue() },
            copySelectionViaKeystroke: { _ in copyCount.calls += 1; return copy() })
    }

    final class CopyCounter: @unchecked Sendable { var calls = 0 }

    func test_rungOne_wins_andNoKeystrokeIsSynthesized() async {
        let counter = CopyCounter()
        let reader = self.reader(axSelectedText: { "Hello there" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .text("Hello there"))
        XCTAssertEqual(resolution.rung, .axSelectedText)
        XCTAssertEqual(counter.calls, 0, "A passive rung succeeded; nothing may be sent to the app.")
    }

    func test_rungTwo_substringsTheValueByTheSelectedRange() async {
        let reader = self.reader(axValue: { "Hello there, Leon" })

        let resolution = await reader.read(target) // range 0..<5

        XCTAssertEqual(resolution.read, .text("Hello"))
        XCTAssertEqual(resolution.rung, .axValueSubstring)
    }

    func test_rungTwo_isSkipped_whenTheRangeIsWithheld() async {
        let hiddenRange = FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "x", selectedRange: nil,
            precedingCharacter: nil, followingCharacter: nil, isSecure: false)
        let reader = self.reader(axValue: { "Hello there, Leon" }, copy: { "copied" })

        let resolution = await reader.read(hiddenRange)

        XCTAssertEqual(resolution.read, .text("copied"),
                       "Without a range the value cannot be sliced; fall through to ⌘C.")
        XCTAssertEqual(resolution.rung, .copyKeystroke)
    }

    func test_rungThree_reached_onlyWhenBothPassiveRungsAreUnreadable() async {
        let counter = CopyCounter()
        let reader = self.reader(copy: { "Can you send the SOW?" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .text("Can you send the SOW?"))
        XCTAssertEqual(resolution.rung, .copyKeystroke)
        XCTAssertEqual(counter.calls, 1)
    }

    func test_allRungsUnreadable_isUnreadable_notEmpty() async {
        let resolution = await reader(copy: { nil }).read(target)
        XCTAssertEqual(resolution.read, .unreadable)
    }

    func test_aReadableEmptySelection_stopsAtRungOne() async {
        let counter = CopyCounter()
        let reader = self.reader(axSelectedText: { "" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .empty)
        XCTAssertEqual(counter.calls, 0, "A real empty answer must not escalate to ⌘C.")
    }
}
