import XCTest
@testable import MustardKit

final class NoteSearchTests: XCTestCase {
    private func entry(_ path: String, _ title: String, _ content: String) -> NoteSearchEntry {
        NoteSearchEntry(project: "KB", relativePath: path, title: title, content: content)
    }

    func test_empty_query_returns_nothing() {
        let e = [entry("notes/A.md", "Alpha", "body")]
        XCTAssertTrue(NoteSearch.match(entries: e, query: "   ").isEmpty)
    }

    func test_matches_title_filename_and_body_case_insensitively() {
        let e = [
            entry("notes/Alpha.md", "Alpha", "nothing here"),
            entry("notes/B.md", "Bravo", "mentions ALPHA in the body"),
            entry("notes/alpha-notes.md", "Zulu", "unrelated"),
        ]
        let hits = NoteSearch.match(entries: e, query: "alpha")
        XCTAssertEqual(Set(hits.map(\.relativePath)),
                       ["notes/Alpha.md", "notes/B.md", "notes/alpha-notes.md"])
    }

    func test_body_only_hit_carries_snippet_title_hit_does_not() {
        let e = [
            entry("notes/Alpha.md", "Alpha", "irrelevant"),               // title hit
            entry("notes/B.md", "Bravo", "line one\nsecond alpha line"),  // body hit
        ]
        let hits = NoteSearch.match(entries: e, query: "alpha")
        let byPath = Dictionary(uniqueKeysWithValues: hits.map { ($0.relativePath, $0) })
        XCTAssertNil(byPath["notes/Alpha.md"]?.snippet)
        XCTAssertEqual(byPath["notes/B.md"]?.snippet, "second alpha line")
    }

    func test_ranking_title_before_filename_before_body() {
        let e = [
            entry("notes/body.md", "Zeta", "has token inside"),   // body → rank 2
            entry("notes/token.md", "Yankee", "nope"),            // filename → rank 1
            entry("notes/x.md", "token thing", "nope"),           // title → rank 0
        ]
        let hits = NoteSearch.match(entries: e, query: "token")
        XCTAssertEqual(hits.map(\.relativePath),
                       ["notes/x.md", "notes/token.md", "notes/body.md"])
    }
}
