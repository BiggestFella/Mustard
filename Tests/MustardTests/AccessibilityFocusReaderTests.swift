import XCTest
@testable import MustardKit

/// The Accessibility focus adapter (Dictation Task 2, BAK-288): snapshots the
/// focused text element through an injected probe and revalidates identity on
/// release. No live AX call ever runs here — probes are constructed directly.
final class AccessibilityFocusReaderTests: XCTestCase {

    // MARK: - Fixtures

    private func probe(
        pid: pid_t = 42,
        role: String? = "AXTextField",
        subrole: String? = nil,
        selectedRange: NSRange? = NSRange(location: 5, length: 0),
        value: String? = "hello world",
        windowTitle: String? = "Notes",
        elementToken: String? = "token-1"
    ) -> AXFocusProbe {
        AXFocusProbe(
            pid: pid, role: role, subrole: subrole, selectedRange: selectedRange,
            value: value, windowTitle: windowTitle, elementToken: elementToken)
    }

    private func reader(
        trusted: Bool = true,
        probe result: @escaping () throws -> AXFocusProbe?
    ) -> AccessibilityFocusReader {
        AccessibilityFocusReader(isTrusted: { trusted }, probe: result)
    }

    // MARK: - Snapshot happy paths

    func test_nativeField_snapshotCarriesRangeAndNeighbors() throws {
        let reader = reader { self.probe() }
        let target = try reader.snapshot()

        XCTAssertEqual(target.applicationPID, 42)
        XCTAssertEqual(target.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertEqual(target.precedingCharacter, "o")
        XCTAssertEqual(target.followingCharacter, " ")
        XCTAssertFalse(target.isSecure)
        XCTAssertTrue(target.elementIdentifier.contains("42"), "identity is anchored to the PID")
    }

    func test_webField_withheldValueStillSnapshots() throws {
        // Web areas often refuse the full value and the selection range.
        let reader = reader {
            self.probe(role: "AXTextArea", selectedRange: nil, value: nil, windowTitle: "Gmail")
        }
        let target = try reader.snapshot()

        XCTAssertNil(target.selectedRange)
        XCTAssertNil(target.precedingCharacter)
        XCTAssertNil(target.followingCharacter)
        XCTAssertFalse(target.isSecure)
    }

    func test_missingRange_neighborsAreNil() throws {
        let reader = reader { self.probe(selectedRange: nil) }
        let target = try reader.snapshot()

        XCTAssertNil(target.precedingCharacter)
        XCTAssertNil(target.followingCharacter)
    }

    func test_selectionAtDocumentEdges_hasNoNeighbors() throws {
        let reader = reader {
            self.probe(selectedRange: NSRange(location: 0, length: 11))
        }
        let target = try reader.snapshot()

        XCTAssertNil(target.precedingCharacter, "nothing precedes the document start")
        XCTAssertNil(target.followingCharacter, "nothing follows the document end")
    }

    func test_surrogatePairNeighbor_readCorrectly() throws {
        // "a👍b" — the thumbs-up is two UTF-16 units; the cursor after it sits
        // at UTF-16 offset 3. The neighbor must come back as one Character.
        let reader = reader {
            self.probe(selectedRange: NSRange(location: 3, length: 0), value: "a👍b")
        }
        let target = try reader.snapshot()

        XCTAssertEqual(target.precedingCharacter, "👍")
        XCTAssertEqual(target.followingCharacter, "b")
    }

    // MARK: - Secure targets (fail closed)

    func test_secureSubrole_isFlaggedSecure() throws {
        let reader = reader { self.probe(subrole: "AXSecureTextField") }
        let target = try reader.snapshot()

        XCTAssertTrue(target.isSecure, "password-shaped fields must be marked so insertion refuses them")
    }

    // MARK: - Snapshot failures

    func test_missingPermission_throws() {
        let reader = reader(trusted: false) { self.probe() }
        XCTAssertThrowsError(try reader.snapshot()) { error in
            XCTAssertEqual(error as? FocusReadError, .accessibilityPermissionMissing)
        }
    }

    func test_deadApplication_throwsUnavailable() {
        let reader = reader { throw FocusReadError.applicationUnavailable }
        XCTAssertThrowsError(try reader.snapshot()) { error in
            XCTAssertEqual(error as? FocusReadError, .applicationUnavailable)
        }
    }

    func test_noFocusedElement_throws() {
        let reader = reader { nil }
        XCTAssertThrowsError(try reader.snapshot()) { error in
            XCTAssertEqual(error as? FocusReadError, .noFocusedTextElement)
        }
    }

    func test_nonTextualRole_throws() {
        let reader = reader { self.probe(role: "AXButton") }
        XCTAssertThrowsError(try reader.snapshot()) { error in
            XCTAssertEqual(error as? FocusReadError, .noFocusedTextElement)
        }
    }

    // MARK: - Paste-delivery check (review fix)

    func test_focusedValueContains_trueWhenTheTextLanded() {
        let reader = reader { self.probe(value: "hello world") }
        XCTAssertEqual(reader.focusedValueContains("hello"), true)
    }

    func test_focusedValueContains_falseWhenTheTextIsMissing() {
        let reader = reader { self.probe(value: "something else") }
        XCTAssertEqual(reader.focusedValueContains("hello"), false)
    }

    func test_focusedValueContains_nilWhenTheValueIsWithheld() {
        let reader = reader { self.probe(value: nil) }
        XCTAssertNil(reader.focusedValueContains("hello"), "unknowable is not failure")
    }

    // MARK: - Revalidation

    func test_isStillFocused_trueForTheSameElement() throws {
        let reader = reader { self.probe() }
        let target = try reader.snapshot()

        XCTAssertTrue(reader.isStillFocused(target))
    }

    func test_isStillFocused_falseOnIdentityMismatch() throws {
        var current = probe()
        let reader = AccessibilityFocusReader(isTrusted: { true }, probe: { current })
        let target = try reader.snapshot()

        current = probe(elementToken: "token-2")

        XCTAssertFalse(reader.isStillFocused(target), "a different element must never receive the insert")
    }

    func test_isStillFocused_falseWhenTheAppDied() throws {
        var shouldThrow = false
        let reader = AccessibilityFocusReader(
            isTrusted: { true },
            probe: {
                if shouldThrow { throw FocusReadError.applicationUnavailable }
                return self.probe()
            })
        let target = try reader.snapshot()

        shouldThrow = true

        XCTAssertFalse(reader.isStillFocused(target))
    }

    func test_isStillFocused_falseWhenPermissionRevokedMidHold() throws {
        var trusted = true
        let reader = AccessibilityFocusReader(isTrusted: { trusted }, probe: { self.probe() })
        let target = try reader.snapshot()

        trusted = false

        XCTAssertFalse(reader.isStillFocused(target))
    }
}
