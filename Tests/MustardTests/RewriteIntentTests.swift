import XCTest
@testable import MustardKit

/// The four phase-1 rewrite intents. Digits are the card's keyboard
/// shortcuts, so they are pinned: a reordered enum must not silently
/// remap ⌘-less 1–4 to different intents.
final class RewriteIntentTests: XCTestCase {

    func test_allCases_areTheFourPhaseOneIntents() {
        XCTAssertEqual(RewriteIntent.allCases,
                       [.proofread, .tighten, .warmer, .direct])
    }

    func test_shortcutDigits_arePinnedOneThroughFour() {
        XCTAssertEqual(RewriteIntent.proofread.shortcutDigit, 1)
        XCTAssertEqual(RewriteIntent.tighten.shortcutDigit, 2)
        XCTAssertEqual(RewriteIntent.warmer.shortcutDigit, 3)
        XCTAssertEqual(RewriteIntent.direct.shortcutDigit, 4)
    }

    func test_intentForDigit_roundTrips_andRejectsOutOfRange() {
        for intent in RewriteIntent.allCases {
            XCTAssertEqual(RewriteIntent(shortcutDigit: intent.shortcutDigit), intent)
        }
        XCTAssertNil(RewriteIntent(shortcutDigit: 0))
        XCTAssertNil(RewriteIntent(shortcutDigit: 5))
    }

    func test_default_isTighten() {
        XCTAssertEqual(RewriteIntent.default, .tighten,
                       "Tighten is the most common ask and the safest default.")
    }

    func test_everyIntent_hasATitleAndANonEmptyInstructionFragment() {
        for intent in RewriteIntent.allCases {
            XCTAssertFalse(intent.title.isEmpty)
            XCTAssertFalse(intent.instructionFragment.isEmpty)
        }
    }
}
