import XCTest
@testable import MustardKit

final class IngestNormalizerTests: XCTestCase {
    private func proposal(source: SourceID, context: String, title: String, action: String,
                           labels: [String]? = nil, sourceURL: String? = nil) -> SourceProposal {
        SourceProposal(source: source, project: "DL", sourceItemID: "t", sourceEventID: "e",
                       sourceContext: context, sourceURL: sourceURL, title: title, actionType: action,
                       labels: labels)
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

    // Labels thread through normalize and take priority over content.
    func test_shortcutNotificationsLabel_classifiesAsShortcut() {
        let p = proposal(source: .gmail, context: "no shortcut wording here",
                         title: "Story assigned", action: "fyi", labels: ["Shortcut Notifications"])
        XCTAssertEqual(IngestNormalizer.normalize(p).source, .shortcut)
    }

    func test_jiraLabel_winsOverContentThatLooksLikeShortcut() {
        let p = proposal(source: .gmail, context: "Shortcut · mentions a story",
                         title: "x", action: "fyi", labels: ["Jira"])
        XCTAssertEqual(IngestNormalizer.normalize(p).source, .jira)
    }

    // Bug: scout occasionally writes a Jira/Atlassian browse link into sourceURL
    // for a Shortcut-sourced rec — the "Open" link then opens the wrong system.
    // normalize() must drop a mismatched-host sourceURL rather than pass it through.
    func test_shortcutSourceWithJiraHostURL_dropsSourceURL() {
        let p = proposal(source: .gmail, context: "", title: "x", action: "fyi",
                         labels: ["Shortcut Notifications"],
                         sourceURL: "https://codeheroes.atlassian.net/browse/DLA-1")
        XCTAssertNil(IngestNormalizer.normalize(p).sourceURL)
    }

    func test_shortcutSourceWithShortcutHostURL_keepsSourceURL() {
        let p = proposal(source: .gmail, context: "", title: "x", action: "fyi",
                         labels: ["Shortcut Notifications"],
                         sourceURL: "https://app.shortcut.com/codeheroes/story/123")
        XCTAssertEqual(IngestNormalizer.normalize(p).sourceURL, "https://app.shortcut.com/codeheroes/story/123")
    }
}
