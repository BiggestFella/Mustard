import XCTest
@testable import MustardKit

/// Selection-length budget. The on-device model's context is small, and the
/// spec refuses oversized selections rather than silently truncating them —
/// truncation would return a rewrite of half the user's paragraph and look
/// like success.
final class RewriteBudgetTests: XCTestCase {

    func test_maxWords_reservesRoomForInstructionsAndOutput() {
        // A rewrite must fit: instructions + selection + a rewrite roughly the
        // size of the selection. So the selection gets well under half the window.
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 4096), 1024)
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 8192), 2048)
    }

    func test_maxWords_neverReturnsLessThanAUsableFloor() {
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 0), RewriteBudget.floorWords)
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 100), RewriteBudget.floorWords,
                       "A nonsense context reading must not make the feature refuse everything.")
    }

    func test_wordCount_countsWhitespaceSeparatedRuns() {
        XCTAssertEqual(RewriteBudget.wordCount("Can you send the SOW?"), 5)
        XCTAssertEqual(RewriteBudget.wordCount("  spaced   out \n lines "), 3)
        XCTAssertEqual(RewriteBudget.wordCount(""), 0)
        XCTAssertEqual(RewriteBudget.wordCount("   "), 0)
    }

    func test_refusalCopy_isUserFacingAndNeverEmpty() {
        let refusals: [RewriteRefusal] = [
            .accessibilityPermissionMissing,
            .secureField,
            .unsupportedRole("AXButton"),
            .noSelection,
            .unreadableSelection(application: "Slack"),
            .overBudget(words: 3000, limit: 1024),
            .focusChanged,
            .model(.appleIntelligenceDisabled),
            .writeFailed("the app didn't accept the paste"),
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal) needs user-facing copy")
        }
    }

    func test_overBudgetCopy_namesBothNumbers() {
        let message = RewriteRefusal.overBudget(words: 3000, limit: 1024).message
        XCTAssertTrue(message.contains("3000"), "The user should see how long the selection is")
        XCTAssertTrue(message.contains("1024"), "…and what the limit is")
    }
}
