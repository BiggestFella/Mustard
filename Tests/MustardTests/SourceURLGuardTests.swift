import XCTest
@testable import MustardKit

final class SourceURLGuardTests: XCTestCase {
    func test_shortcutSourceWithJiraHost_dropsURL() {
        XCTAssertNil(SourceURLGuard.guarded(source: .shortcut, sourceURL: "https://codeheroes.atlassian.net/browse/DLA-1"))
    }

    func test_shortcutSourceWithJiraWordInHost_dropsURL() {
        XCTAssertNil(SourceURLGuard.guarded(source: .shortcut, sourceURL: "https://jira.codeheroes.com.au/browse/DLA-1"))
    }

    func test_shortcutSourceWithShortcutHost_keepsURL() {
        XCTAssertEqual(
            SourceURLGuard.guarded(source: .shortcut, sourceURL: "https://app.shortcut.com/codeheroes/story/123"),
            "https://app.shortcut.com/codeheroes/story/123"
        )
    }

    func test_nonShortcutSource_passesThroughUnchanged() {
        XCTAssertEqual(
            SourceURLGuard.guarded(source: .jira, sourceURL: "https://codeheroes.atlassian.net/browse/DLA-1"),
            "https://codeheroes.atlassian.net/browse/DLA-1"
        )
    }

    func test_nilURL_staysNil() {
        XCTAssertNil(SourceURLGuard.guarded(source: .shortcut, sourceURL: nil))
    }

    func test_malformedURL_passesThroughUnchanged() {
        XCTAssertEqual(SourceURLGuard.guarded(source: .shortcut, sourceURL: "not a url"), "not a url")
    }
}
