import XCTest
@testable import MustardKit

final class OriginalSourceDisplayTests: XCTestCase {
    private let gmailURL = "https://mail.google.com/mail/u/0/#all/m1"

    func test_sectionLabel_gmailSource_isOriginalEmail() {
        XCTAssertEqual(OriginalSourceDisplay.sectionLabel(source: "gmail", sourceURL: nil),
                       "ORIGINAL EMAIL")
    }

    func test_sectionLabel_reclassifiedJiraWithGmailPermalink_isOriginalEmail() {
        // IngestNormalizer rewrites source to jira/shortcut; the permalink is the
        // durable Gmail-transport signal (same as Send/Archive gating).
        XCTAssertEqual(
            OriginalSourceDisplay.sectionLabel(source: "jira", sourceURL: gmailURL),
            "ORIGINAL EMAIL")
        XCTAssertEqual(
            OriginalSourceDisplay.sectionLabel(source: "shortcut", sourceURL: gmailURL),
            "ORIGINAL EMAIL")
    }

    func test_sectionLabel_nonGmail_isOriginalSource() {
        XCTAssertEqual(OriginalSourceDisplay.sectionLabel(source: "vault", sourceURL: nil),
                       "ORIGINAL SOURCE")
        XCTAssertEqual(
            OriginalSourceDisplay.sectionLabel(source: "jira",
                                               sourceURL: "https://app.shortcut.com/story/1"),
            "ORIGINAL SOURCE")
    }

    func test_isPresent_rejectsNilBlankAndWhitespace() {
        XCTAssertFalse(OriginalSourceDisplay.isPresent(nil))
        XCTAssertFalse(OriginalSourceDisplay.isPresent(""))
        XCTAssertFalse(OriginalSourceDisplay.isPresent("   \n  "))
        XCTAssertTrue(OriginalSourceDisplay.isPresent("Hi Leon"))
    }

    func test_preview_leavesShortTextUnchanged() {
        XCTAssertEqual(OriginalSourceDisplay.preview("please review"), "please review")
        XCTAssertEqual(OriginalSourceDisplay.previewText("please review"), "please review")
        XCTAssertNil(OriginalSourceDisplay.previewText(nil))
        XCTAssertNil(OriginalSourceDisplay.previewText("  "))
    }

    func test_preview_clipsLongBodyAndAddsEllipsis() {
        let long = String(repeating: "x", count: OriginalSourceDisplay.previewCharLimit + 40)
        let out = OriginalSourceDisplay.preview(long)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertLessThan(out.count, long.count)
        XCTAssertEqual(out.dropLast().count, OriginalSourceDisplay.previewCharLimit)
    }

    func test_preview_clipsToLineLimit() {
        let lines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let out = OriginalSourceDisplay.preview(lines)
        XCTAssertEqual(out, "line 1\nline 2\nline 3…")
    }

    func test_isCollapsible_falseForShortBodies() {
        XCTAssertFalse(OriginalSourceDisplay.isCollapsible("short"))
        XCTAssertEqual(OriginalSourceDisplay.collapsed("short"), "short")
    }

    func test_isCollapsible_trueWhenOverCharLimit() {
        let long = String(repeating: "a", count: OriginalSourceDisplay.collapsedCharLimit + 1)
        XCTAssertTrue(OriginalSourceDisplay.isCollapsible(long))
        let out = OriginalSourceDisplay.collapsed(long)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertEqual(out.dropLast().count, OriginalSourceDisplay.collapsedCharLimit)
    }

    func test_isCollapsible_trueWhenOverLineLimit() {
        let lines = (1...12).map { "L\($0)" }.joined(separator: "\n")
        XCTAssertTrue(OriginalSourceDisplay.isCollapsible(lines))
        let expected = (1...OriginalSourceDisplay.collapsedLineLimit)
            .map { "L\($0)" }.joined(separator: "\n") + "…"
        XCTAssertEqual(OriginalSourceDisplay.collapsed(lines), expected)
    }
}
