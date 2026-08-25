import XCTest
@testable import MustardKit

final class IngestNormalizerTests: XCTestCase {
    private func proposal(source: SourceID, context: String, title: String, action: String) -> SourceProposal {
        SourceProposal(source: source, project: "DL", sourceItemID: "t", sourceEventID: "e",
                       sourceContext: context, title: title, actionType: action)
    }

    func test_shortcutPOReviewInTitle_demotesToIgnore() {
        let p = proposal(source: .gmail,
                         context: "Shortcut · Digital Licence · Tom added sub-task assigned to Leon",
                         title: "Complete PO Review sub-task (DLV Favourite Bundles)",
                         action: "create_task")
        let out = IngestNormalizer.normalize(p)
        XCTAssertEqual(out.source, .shortcut)
        XCTAssertEqual(out.actionType, "ignore")
    }

    func test_shortcutPOReviewInContext_demotesToIgnore() {
        let p = proposal(source: .gmail,
                         context: "Shortcut · Digital Licence · added sub-task 'PO Review' to Leon",
                         title: "Some other title", action: "vault_note")
        XCTAssertEqual(IngestNormalizer.normalize(p).actionType, "ignore")
    }

    func test_shortcutWithoutPOReview_keepsAction() {
        let p = proposal(source: .gmail, context: "Shortcut · Digital Licence · comment added",
                         title: "Reply to comment", action: "draft_email")
        let out = IngestNormalizer.normalize(p)
        XCTAssertEqual(out.source, .shortcut)
        XCTAssertEqual(out.actionType, "draft_email")
    }

    func test_jiraWithPOReviewWording_isNotIgnored() {
        // PO-review demotion is scoped to Shortcut; a Jira item is unaffected.
        let p = proposal(source: .gmail, context: "Jira · DLA-1 · PO Review mentioned",
                         title: "PO Review note", action: "create_task")
        let out = IngestNormalizer.normalize(p)
        XCTAssertEqual(out.source, .jira)
        XCTAssertEqual(out.actionType, "create_task")
    }

    func test_genericGmail_passesThroughUnchanged() {
        let p = proposal(source: .gmail, context: "App Store Connect · rejected",
                         title: "x", action: "fyi")
        let out = IngestNormalizer.normalize(p)
        XCTAssertEqual(out.source, .gmail)
        XCTAssertEqual(out.actionType, "fyi")
    }

    func test_normalize_preservesOriginalSourceThroughReclassify() {
        let p = SourceProposal(
            source: .gmail, project: "DL", sourceItemID: "t", sourceEventID: "e",
            sourceContext: "Jira · DLA-1 · comment added",
            sourceURL: "https://mail.google.com/mail/u/0/#all/m1",
            title: "Reply to comment", actionType: "create_task",
            originalSource: "the original email body")
        let out = IngestNormalizer.normalize(p)
        XCTAssertEqual(out.source, .jira)
        XCTAssertEqual(out.originalSource, "the original email body")
    }
}
