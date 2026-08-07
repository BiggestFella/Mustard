import XCTest
@testable import MustardKit

final class WikilinkAutocompleteTests: XCTestCase {
    func test_activeQuery_inside_open_link() {
        // "see [[al" caret at end (len 8)
        let q = WikilinkAutocomplete.activeQuery(text: "see [[al", caretUTF16: 8)
        XCTAssertEqual(q?.text, "al")
        XCTAssertEqual(q?.range, NSRange(location: 4, length: 4)) // "[[al"
    }

    func test_nil_when_link_already_closed() {
        // "[[done]] more" caret at end
        XCTAssertNil(WikilinkAutocomplete.activeQuery(text: "[[done]] more", caretUTF16: 13))
    }

    func test_nil_when_newline_between_open_and_caret() {
        XCTAssertNil(WikilinkAutocomplete.activeQuery(text: "[[a\nb", caretUTF16: 5))
    }

    func test_empty_query_right_after_brackets() {
        let q = WikilinkAutocomplete.activeQuery(text: "x [[", caretUTF16: 4)
        XCTAssertEqual(q?.text, "")
    }

    func test_candidates_prefix_before_substring_each_alphabetical() {
        let titles = ["Roadmap", "Beta Roadmap", "Roads", "Alpha"]
        XCTAssertEqual(
            WikilinkAutocomplete.candidates(query: "road", titles: titles),
            ["Roadmap", "Roads", "Beta Roadmap"]) // prefix (A→Z) then substring
    }

    func test_empty_query_returns_all_titles_unchanged() {
        XCTAssertEqual(WikilinkAutocomplete.candidates(query: "", titles: ["B", "A"]), ["B", "A"])
    }

    // MARK: Stem-targeted insertion (final-review #1/#2 — links resolve by stem)

    func test_rank_orders_by_title_and_keeps_stems() {
        let cands = [
            WikilinkAutocomplete.LinkCandidate(title: "Standup 2026-07-20", stem: "2026-07-20-standup"),
            WikilinkAutocomplete.LinkCandidate(title: "Roadmap", stem: "Roadmap"),
        ]
        let ranked = WikilinkAutocomplete.rank(query: "stand", candidates: cands)
        XCTAssertEqual(ranked.map(\.stem), ["2026-07-20-standup"])
    }

    func test_insertion_uses_bare_stem_when_title_matches() {
        let c = WikilinkAutocomplete.LinkCandidate(title: "Roadmap", stem: "Roadmap")
        XCTAssertEqual(WikilinkAutocomplete.insertion(for: c), "[[Roadmap]]")
    }

    func test_insertion_aliases_title_when_stem_differs() {
        let c = WikilinkAutocomplete.LinkCandidate(title: "Standup 2026-07-20", stem: "2026-07-20-standup")
        XCTAssertEqual(WikilinkAutocomplete.insertion(for: c),
                       "[[2026-07-20-standup|Standup 2026-07-20]]")
    }

    func test_stem_of_path() {
        XCTAssertEqual(WikilinkAutocomplete.stem(ofPath: "notes/guides/Setup.md"), "Setup")
        XCTAssertEqual(WikilinkAutocomplete.stem(ofPath: "Top.md"), "Top")
    }
}
