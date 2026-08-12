import XCTest
@testable import MustardKit

final class NotchSearchTests: XCTestCase {
    private struct Row: NotchSearchable {
        let uid: String
        let searchText: String
    }

    private let rows = [
        Row(uid: "1", searchText: "https://supaste.com Safari"),
        Row(uid: "2", searchText: "ssh deploy@prod Terminal"),
        Row(uid: "3", searchText: "Design review notes Dictation"),
        Row(uid: "4", searchText: "#2D7FF9 Figma"),
    ]

    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(NotchSearch.filter(rows, query: "").map(\.uid), ["1", "2", "3", "4"])
        XCTAssertEqual(NotchSearch.filter(rows, query: "  ").map(\.uid), ["1", "2", "3", "4"])
    }

    func testSubstringMatchesCaseInsensitive() {
        XCTAssertEqual(NotchSearch.filter(rows, query: "SUPASTE").map(\.uid), ["1"])
        XCTAssertEqual(NotchSearch.filter(rows, query: "deploy").map(\.uid), ["2"])
    }

    func testSubsequenceMatches() {
        // "dsgnrv" is a subsequence of "Design review".
        XCTAssertEqual(NotchSearch.filter(rows, query: "dsgnrv").map(\.uid), ["3"])
    }

    func testSubstringRanksAboveSubsequence() {
        let mixed = [
            Row(uid: "sub", searchText: "abcdef"),      // subsequence match for "ace"
            Row(uid: "exact", searchText: "an ace card"),  // substring match for "ace"
        ]
        XCTAssertEqual(NotchSearch.filter(mixed, query: "ace").map(\.uid), ["exact", "sub"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(NotchSearch.filter(rows, query: "zzzz").isEmpty)
    }
}
