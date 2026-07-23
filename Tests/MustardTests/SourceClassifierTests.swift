import XCTest
@testable import MustardKit

final class SourceClassifierTests: XCTestCase {
    func test_gmailWithJiraLeadingToken_isJira() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Jira · DLA-5280 · mentioned"), .jira)
    }

    func test_gmailWithShortcutLeadingToken_isShortcut() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Shortcut · Digital Licence · sub-task"), .shortcut)
    }

    func test_gmailWithTicketKeyOnly_fallsBackToJira() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Mentioned on DLA-5280"), .jira)
    }

    func test_gmailUnrelatedContext_staysGmail() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "App Store Connect · SalesBuddi · app rejected"), .gmail)
    }

    func test_gmailEmptyContext_staysGmail() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: ""), .gmail)
    }

    func test_nonGmailTransport_isNeverReclassified() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .vault, sourceContext: "Jira · DLA-1"), .vault)
    }

    // Labels are ground truth (Jira/Shortcut robots are auto-filtered into Gmail
    // labels); they take priority over any content heuristic.
    func test_labelJira_isJira() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "", labels: ["Jira"]), .jira)
    }

    func test_labelJiraUpdates_isJira() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "", labels: ["Jira Updates"]), .jira)
    }

    func test_labelShortcutNotifications_isShortcut() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "", labels: ["Shortcut Notifications"]), .shortcut)
    }

    func test_labelIsCaseInsensitive() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "", labels: ["shortcut notifications"]), .shortcut)
    }

    // A human reply merely mentioning a ticket key must not be mislabeled once a
    // real label is present — labels win over the ticket-key regex, no fallback.
    func test_labelsPresentWithoutMatch_overridesContentRegex_staysGmail() {
        XCTAssertEqual(
            SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Mentioned on DLA-5280", labels: ["Inbox", "Important"]),
            .gmail
        )
    }

    func test_noLabels_fallsBackToContentHeuristic() {
        XCTAssertEqual(SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Jira · DLA-5280 · mentioned", labels: []), .jira)
    }

    // Fixes the mid-string mislabel: real scout provenance is "Gmail · Shortcut ·
    // <subject>" — "Shortcut" is a token after "Gmail · ", not a string prefix.
    func test_noLabels_midStringShortcutToken_isShortcut() {
        XCTAssertEqual(
            SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Gmail · Shortcut · Fahad flags Android CI build failing", labels: []),
            .shortcut
        )
    }

    func test_noLabels_midStringJiraToken_isJira() {
        XCTAssertEqual(
            SourceClassifier.logicalSource(transport: .gmail, sourceContext: "Gmail · Jira · comment added", labels: []),
            .jira
        )
    }
}
