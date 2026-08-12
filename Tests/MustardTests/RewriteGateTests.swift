import XCTest
@testable import MustardKit

/// The gate, split around the read. `admits` runs BEFORE anything is read —
/// this ordering is load-bearing, because read rung 3 synthesizes ⌘C into the
/// target and must never be reached for a password field.
final class RewriteGateTests: XCTestCase {

    private func target(
        role: String = "AXTextArea",
        selectedRange: NSRange? = NSRange(location: 0, length: 12),
        isSecure: Bool = false
    ) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501,
            elementIdentifier: "501#token#\(role)#Window",
            selectedRange: selectedRange,
            precedingCharacter: nil,
            followingCharacter: nil,
            isSecure: isSecure)
    }

    // MARK: - admits (pre-read)

    func test_admits_aNormalTextAreaWithASelection() {
        XCTAssertNil(RewriteGate.admits(target: target(), role: "AXTextArea", hasAccessibility: true))
    }

    func test_admits_refusesASecureField_beforeAnythingIsRead() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(isSecure: true), role: "AXTextField", hasAccessibility: true),
            .secureField,
            "A password field must be refused before rung 3 can synthesize ⌘C.")
    }

    func test_admits_refusesSecureField_evenBeforeMissingPermission() {
        // Ordering guard: if both are wrong, the secure refusal is the one that
        // matters, and it must not be masked by a permission message.
        XCTAssertEqual(
            RewriteGate.admits(target: target(isSecure: true), role: "AXTextField", hasAccessibility: false),
            .secureField)
    }

    func test_admits_refusesMissingAccessibility() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(), role: "AXTextArea", hasAccessibility: false),
            .accessibilityPermissionMissing)
    }

    func test_admits_refusesAnUnsupportedRole_namingIt() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(role: "AXButton"), role: "AXButton", hasAccessibility: true),
            .unsupportedRole("AXButton"))
    }

    func test_admits_refusesAZeroLengthSelection() {
        XCTAssertEqual(
            RewriteGate.admits(
                target: target(selectedRange: NSRange(location: 4, length: 0)),
                role: "AXTextArea", hasAccessibility: true),
            .noSelection,
            "A bare cursor is not a selection; rewriting the whole field could destroy a draft.")
    }

    func test_admits_allowsAHiddenRange_becauseWebAreasWithholdIt() {
        // nil range is 'unknown', not 'empty' — the ⌘C rung can still recover
        // the selection, so refusing here would lose Gmail and Slack.
        XCTAssertNil(
            RewriteGate.admits(target: target(selectedRange: nil), role: "AXWebArea", hasAccessibility: true))
    }

    // MARK: - accepts (post-read)

    func test_accepts_returnsTheTrimmedSelection() {
        let result = RewriteGate.accepts(
            read: .text("  Can you send the SOW?  "), application: "Mail", maxWords: 1024)
        XCTAssertEqual(try? result.get(), "Can you send the SOW?")
    }

    func test_accepts_refusesEmpty() {
        let result = RewriteGate.accepts(read: .empty, application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.rewriteFailure, .noSelection)
    }

    func test_accepts_refusesWhitespaceOnlyTextAsEmpty() {
        let result = RewriteGate.accepts(read: .text("   \n  "), application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.rewriteFailure, .noSelection)
    }

    func test_accepts_refusesUnreadable_namingTheApplication() {
        let result = RewriteGate.accepts(read: .unreadable, application: "Slack", maxWords: 1024)
        XCTAssertEqual(result.rewriteFailure, .unreadableSelection(application: "Slack"))
    }

    func test_accepts_refusesOverBudget_reportingBothNumbers() {
        let long = Array(repeating: "word", count: 1200).joined(separator: " ")
        let result = RewriteGate.accepts(read: .text(long), application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.rewriteFailure, .overBudget(words: 1200, limit: 1024))
    }

    func test_accepts_allowsExactlyTheLimit() {
        let exact = Array(repeating: "word", count: 1024).joined(separator: " ")
        let result = RewriteGate.accepts(read: .text(exact), application: "Mail", maxWords: 1024)
        XCTAssertNotNil(try? result.get(), "The limit is inclusive.")
    }
}

// Small test-only convenience for reading Result failures. Named
// `rewriteFailure` rather than `failure` so it cannot collide with another
// test file's helper in the same target.
extension Result {
    var rewriteFailure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
