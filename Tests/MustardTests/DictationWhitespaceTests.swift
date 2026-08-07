import XCTest
@testable import MustardKit

/// Pure contextual whitespace + target-identity rules for system-wide dictation.
/// `DictationWhitespace.insertion(text:target:)` returns the exact replacement
/// string, or nil when insertion must not happen (secure target, nothing to say).
final class DictationWhitespaceTests: XCTestCase {

    /// A plain editable target at an empty cursor, with the surrounding
    /// characters under test injected explicitly.
    private func target(
        selectedRange: NSRange? = NSRange(location: 5, length: 0),
        preceding: Character? = nil,
        following: Character? = nil,
        isSecure: Bool = false,
        pid: pid_t = 42,
        element: String = "field-1"
    ) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: pid,
            elementIdentifier: element,
            selectedRange: selectedRange,
            precedingCharacter: preceding,
            followingCharacter: following,
            isSecure: isSecure
        )
    }

    // MARK: - Selection replacement

    func test_nonEmptySelection_insertsExactTranscript() {
        // Replacing a selection never pads, even between word characters —
        // the selection already owned the boundary.
        let t = target(selectedRange: NSRange(location: 3, length: 8),
                       preceding: "a", following: "b")
        XCTAssertEqual(DictationWhitespace.insertion(text: "hello there", target: t),
                       "hello there")
    }

    func test_zeroLengthSelection_isACursor_andPads() {
        let t = target(selectedRange: NSRange(location: 3, length: 0),
                       preceding: "a", following: "b")
        XCTAssertEqual(DictationWhitespace.insertion(text: "hello", target: t),
                       " hello ")
    }

    // MARK: - Letters and digits on both sides

    func test_lettersBothSides_padsBothSides() {
        let t = target(preceding: "d", following: "T")
        XCTAssertEqual(DictationWhitespace.insertion(text: "new words", target: t),
                       " new words ")
    }

    func test_digitsCountAsWordCharacters() {
        let t = target(preceding: "3", following: "7")
        XCTAssertEqual(DictationWhitespace.insertion(text: "plus 4 equals", target: t),
                       " plus 4 equals ")
    }

    func test_letterBefore_only_padsLeadingOnly() {
        let t = target(preceding: "d", following: nil)
        XCTAssertEqual(DictationWhitespace.insertion(text: "more", target: t), " more")
    }

    func test_letterAfter_only_padsTrailingOnly() {
        let t = target(preceding: nil, following: "T")
        XCTAssertEqual(DictationWhitespace.insertion(text: "more", target: t), "more ")
    }

    // MARK: - Punctuation

    func test_beforeClosingPunctuation_noTrailingSpace() {
        // Cursor sits right before "." — never insert a space before it.
        let t = target(preceding: "d", following: ".")
        XCTAssertEqual(DictationWhitespace.insertion(text: "and more", target: t),
                       " and more")
    }

    func test_beforeClosingParenAndComma_noTrailingSpace() {
        for close: Character in [")", ",", "]", "!", "?", ";", ":"] {
            let t = target(preceding: nil, following: close)
            XCTAssertEqual(DictationWhitespace.insertion(text: "inside", target: t),
                           "inside", "no space before \(close)")
        }
    }

    func test_afterOpeningPunctuation_noLeadingSpace() {
        let t = target(preceding: "(", following: nil)
        XCTAssertEqual(DictationWhitespace.insertion(text: "quoted", target: t), "quoted")
    }

    func test_transcriptEndingInPunctuation_neverGrowsTrailingSpace() {
        // "Hello." + following letter: the boundary pair is "." / "T" — not two
        // word characters, so no space is added.
        let t = target(preceding: nil, following: "T")
        XCTAssertEqual(DictationWhitespace.insertion(text: "Hello.", target: t), "Hello.")
    }

    func test_transcriptStartingWithPunctuation_neverGrowsLeadingSpace() {
        let t = target(preceding: "d", following: nil)
        XCTAssertEqual(DictationWhitespace.insertion(text: "...pause", target: t), "...pause")
    }

    func test_existingSpaceBeside_neverDoubles() {
        let t = target(preceding: " ", following: " ")
        XCTAssertEqual(DictationWhitespace.insertion(text: "word", target: t), "word")
    }

    // MARK: - Newlines

    func test_afterNewline_noLeadingSpace() {
        let t = target(preceding: "\n", following: nil)
        XCTAssertEqual(DictationWhitespace.insertion(text: "fresh line", target: t),
                       "fresh line")
    }

    func test_beforeNewline_noTrailingSpace() {
        let t = target(preceding: "d", following: "\n")
        XCTAssertEqual(DictationWhitespace.insertion(text: "end of line", target: t),
                       " end of line")
    }

    func test_betweenNewlines_exactTranscript() {
        let t = target(preceding: "\n", following: "\n")
        XCTAssertEqual(DictationWhitespace.insertion(text: "own paragraph", target: t),
                       "own paragraph")
    }

    // MARK: - Empty documents

    func test_emptyDocument_noSurroundingCharacters_exactTranscript() {
        let t = target(selectedRange: NSRange(location: 0, length: 0),
                       preceding: nil, following: nil)
        XCTAssertEqual(DictationWhitespace.insertion(text: "first words", target: t),
                       "first words")
    }

    func test_unknownRange_stillTreatedAsCursor() {
        // Some AX elements expose no selected range; padding rules still apply
        // from the adjacent characters alone.
        let t = target(selectedRange: nil, preceding: "a", following: "b")
        XCTAssertEqual(DictationWhitespace.insertion(text: "middle", target: t),
                       " middle ")
    }

    func test_emptyTranscript_yieldsNoInsertion() {
        // An empty replacement would silently delete a selection — never emit one.
        let t = target(selectedRange: NSRange(location: 0, length: 4),
                       preceding: "a", following: "b")
        XCTAssertNil(DictationWhitespace.insertion(text: "", target: t))
    }

    // MARK: - Protected (secure) targets

    func test_secureTarget_neverYieldsInsertion() {
        let t = target(preceding: "a", following: "b", isSecure: true)
        XCTAssertNil(DictationWhitespace.insertion(text: "hunter2", target: t))
    }

    func test_secureTarget_withSelection_neverYieldsInsertion() {
        let t = target(selectedRange: NSRange(location: 0, length: 9), isSecure: true)
        XCTAssertNil(DictationWhitespace.insertion(text: "password", target: t))
    }

    func test_secureTarget_emptyDocument_neverYieldsInsertion() {
        let t = target(selectedRange: NSRange(location: 0, length: 0),
                       preceding: nil, following: nil, isSecure: true)
        XCTAssertNil(DictationWhitespace.insertion(text: "secret", target: t))
    }

    // MARK: - Target identity (revalidation on release)

    func test_identicalSnapshots_areEqual() {
        XCTAssertEqual(target(), target())
    }

    func test_changedElementIdentifier_isADifferentTarget() {
        XCTAssertNotEqual(target(element: "field-1"), target(element: "field-2"))
    }

    func test_changedApplicationPID_isADifferentTarget() {
        XCTAssertNotEqual(target(pid: 42), target(pid: 43))
    }

    func test_changedSelection_isADifferentTarget() {
        // The cursor moved during dictation — the snapshot no longer matches.
        XCTAssertNotEqual(target(selectedRange: NSRange(location: 5, length: 0)),
                          target(selectedRange: NSRange(location: 9, length: 0)))
    }

    func test_secureFlagFlip_isADifferentTarget() {
        XCTAssertNotEqual(target(isSecure: false), target(isSecure: true))
    }
}
