import XCTest
@testable import MustardKit

final class NotePreviewTests: XCTestCase {
    func test_strips_frontmatter_and_blank_lines_and_honors_maxLines() {
        let content = "---\ntitle: X\ntags: []\n---\n\n# Heading\n\nFirst para.\nSecond para.\nThird para.\n"
        XCTAssertEqual(NotePreview.excerpt(content: content, maxLines: 2), "# Heading\nFirst para.")
    }

    func test_short_note_returns_what_it_has() {
        XCTAssertEqual(NotePreview.excerpt(content: "just one line", maxLines: 4), "just one line")
    }

    func test_empty_content_is_empty() {
        XCTAssertEqual(NotePreview.excerpt(content: "---\ntitle: X\n---\n", maxLines: 3), "")
    }
}
