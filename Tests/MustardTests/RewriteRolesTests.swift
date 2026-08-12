import XCTest
@testable import MustardKit

/// Rewrite's own AX role policy. It is deliberately SEPARATE from
/// `AccessibilityFocusReader.textualRoles`, which dictation shares and which
/// is not yet hardware-verified — widening that set to catch Chromium web
/// areas would destabilise a feature still being proven.
final class RewriteRolesTests: XCTestCase {

    func test_admits_theNativeTextualRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(RewriteRoles.admits(role: role), "\(role) should be rewritable")
        }
    }

    func test_admits_webArea_whichDictationDoesNot() {
        XCTAssertTrue(RewriteRoles.admits(role: "AXWebArea"),
                      "Chromium apps focus a web area; rewrite must reach Gmail and Slack.")
        XCTAssertFalse(AccessibilityFocusReader.textualRoles.contains("AXWebArea"),
                       "Dictation's shared set must stay untouched by this change.")
    }

    func test_refuses_nonTextualRolesAndNil() {
        XCTAssertFalse(RewriteRoles.admits(role: "AXButton"))
        XCTAssertFalse(RewriteRoles.admits(role: "AXImage"))
        XCTAssertFalse(RewriteRoles.admits(role: nil))
    }
}
