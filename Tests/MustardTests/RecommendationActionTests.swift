import XCTest
@testable import MustardKit

final class RecommendationActionTests: XCTestCase {
    func test_parse_knownTokens() {
        XCTAssertEqual(RecommendationAction.parse("draft_email"), .draftEmail)
        XCTAssertEqual(RecommendationAction.parse("vault_note"), .vaultNote)
        XCTAssertEqual(RecommendationAction.parse("ticket_write"), .ticket)
    }

    func test_parse_unknownIsNil() {
        XCTAssertNil(RecommendationAction.parse("draft_emial"))
        XCTAssertNil(RecommendationAction.parse(""))
        XCTAssertNil(RecommendationAction.parse("send_email"))
    }

    func test_from_unknownFallsBackToVaultNoteForDisplayOnly() {
        XCTAssertEqual(RecommendationAction.from("draft_emial"), .vaultNote)
    }
}
