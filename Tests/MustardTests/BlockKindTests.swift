import XCTest
@testable import MustardKit

/// BlockKind classification (Craft menus spec, Phase 0 / BAK-249): the canonical
/// block-type enum `SlashMenu`, the future "turn into" transform, and this suite
/// all consume. `NoteDecoration.blockKind(_:of:)` is the one classifier — these
/// tests pin its mapping from `NoteDecoration`'s existing line/block partitioner.
final class BlockKindTests: XCTestCase {

    private typealias Block = NoteDecoration.Block

    /// Classifies every block of `source` in partition order — the shape most
    /// fixtures want (one source, N blocks, N expected kinds).
    private func kinds(_ source: String) -> [BlockKind?] {
        NoteDecoration.blocks(source).map { NoteDecoration.blockKind(source, of: $0) }
    }

    // MARK: - One fixture per kind

    func test_paragraph_plainTextLine() {
        XCTAssertEqual(kinds("just a paragraph line"), [.paragraph])
    }

    func test_heading_levelsOneThroughFour() {
        XCTAssertEqual(NoteDecoration.blockKind("# H", of: NoteDecoration.blocks("# H")[0]), .heading(1))
        XCTAssertEqual(NoteDecoration.blockKind("## H", of: NoteDecoration.blocks("## H")[0]), .heading(2))
        XCTAssertEqual(NoteDecoration.blockKind("### H", of: NoteDecoration.blocks("### H")[0]), .heading(3))
        XCTAssertEqual(NoteDecoration.blockKind("#### H", of: NoteDecoration.blocks("#### H")[0]), .heading(4))
    }

    /// h5/h6 aren't in the Phase-2 insert menu's 1...4 range, but existing vault
    /// content can already contain them (`NoteDecoration.spans` has always
    /// rendered `#####`/`######` as real headings — see `headingLevel`, which
    /// accepts 1...6). Classification must not lie about a block's real level, so
    /// it passes the true level through unclamped: never changes how headings
    /// render (spec constraint), and callers that only offer 1...4 (the insert
    /// menu) simply never produce 5/6 themselves.
    func test_heading_levelFiveAndSix_passThroughUnclamped_notClamped() {
        XCTAssertEqual(NoteDecoration.blockKind("##### H", of: NoteDecoration.blocks("##### H")[0]), .heading(5))
        XCTAssertEqual(NoteDecoration.blockKind("###### H", of: NoteDecoration.blocks("###### H")[0]), .heading(6))
    }

    func test_quote() {
        XCTAssertEqual(kinds("> hi"), [.quote])
    }

    func test_bulletList() {
        XCTAssertEqual(kinds("- item"), [.bulletList])
        XCTAssertEqual(kinds("* item"), [.bulletList])
    }

    func test_numberedList() {
        XCTAssertEqual(kinds("1. item"), [.numberedList])
    }

    func test_todoList_uncheckedAndChecked() {
        XCTAssertEqual(kinds("- [ ] task"), [.todoList])
        XCTAssertEqual(kinds("- [x] task"), [.todoList])
        XCTAssertEqual(kinds("- [X] task"), [.todoList])
        XCTAssertEqual(kinds("* [ ] task"), [.todoList])
    }

    func test_codeBlock() {
        XCTAssertEqual(kinds("```\ncode\n```"), [.codeBlock])
    }

    func test_divider() {
        XCTAssertEqual(kinds("---\ntext"), [.divider, .paragraph])
        XCTAssertEqual(kinds("***"), [.divider])
    }

    func test_table_pipeRowsWithSeparator() {
        XCTAssertEqual(kinds("| a | b |\n|---|---|\n| 1 | 2 |\n"), [.table])
    }

    func test_image_bareImageLine() {
        XCTAssertEqual(kinds("![alt](url)"), [.image])
    }

    func test_subpage_bareWikilinkLine() {
        XCTAssertEqual(kinds("[[Target]]"), [.subpage])
    }

    // MARK: - Frontmatter: not a BlockKind case

    /// Frontmatter stays a partitioner-internal concept (`Block.isFrontmatter`),
    /// not a `BlockKind` case — the spec's enum has no `.frontmatter` case (it
    /// isn't a block a "turn into"/insert menu would ever offer or convert to/
    /// from), and `NoteDecoration.Kind.frontmatter` already exists one layer down
    /// for span styling. `blockKind` returns `nil` for a frontmatter block; every
    /// other block kind always classifies to a non-nil case.
    func test_frontmatterBlock_hasNoBlockKind_returnsNil() {
        let source = "---\ntitle: x\n---\nbody"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertTrue(blocks[0].isFrontmatter)
        XCTAssertNil(NoteDecoration.blockKind(source, of: blocks[0]))
        XCTAssertEqual(NoteDecoration.blockKind(source, of: blocks[1]), .paragraph)
    }

    func test_frontmatterOnlyDoc_singleBlock_classifiesNil() {
        let source = "---\ntitle: x\n---\n"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(NoteDecoration.blockKind(source, of: blocks[0]))
    }

    // MARK: - Edge cases

    func test_emptyDoc_noBlocksToClassify() {
        XCTAssertEqual(NoteDecoration.blocks(""), [])
        XCTAssertEqual(kinds(""), [])
    }

    func test_todoVsBullet_mixedList_classifiesPerLine() {
        // Bullets are one block per line in the existing partitioner, so a mixed
        // list is a straightforward per-block classification, not a special case.
        XCTAssertEqual(kinds("- plain\n- [ ] task\n- [x] done\n- plain again"),
                       [.bulletList, .todoList, .todoList, .bulletList])
    }

    func test_tableWithoutSeparatorRow_isNotATable_staysParagraph() {
        XCTAssertEqual(kinds("| a | b |\n| c | d |\n"), [.paragraph])
    }

    func test_imageLineWithTrailingText_isNotAnImage_staysParagraph() {
        XCTAssertEqual(kinds("![alt](url) trailing text"), [.paragraph])
    }

    func test_imageSyntaxNotAloneInBlock_staysParagraph() {
        // Two lines with no blank separator merge into one paragraph block (the
        // existing partitioner's rule for consecutive `.text` lines) — "solely"
        // means the block's only content line, not just any line containing it.
        XCTAssertEqual(kinds("![alt](url)\nmore text"), [.paragraph])
    }

    func test_wikilinkWithAliasAnchorOrEmbed_isNotSubpage_staysParagraph() {
        for source in ["[[T|alias]]", "[[T#anchor]]", "![[T]]"] {
            XCTAssertEqual(kinds(source), [.paragraph], "unexpected kind for \(source)")
        }
    }

    func test_mixedDoc_eachBlockClassifiedInOrder() {
        let source = """
        # Title

        para one

        - a
        - [ ] b

        > q

        ---

        ```
        code
        ```

        | x | y |
        |---|---|
        | 1 | 2 |

        ![alt](img.png)

        [[Sub]]
        """
        XCTAssertEqual(kinds(source), [
            .heading(1),
            .paragraph,
            .bulletList,
            .todoList,
            .quote,
            .divider,
            .codeBlock,
            .table,
            .image,
            .subpage,
        ])
    }
}
