import XCTest
@testable import MustardKit

final class SlashMenuTests: XCTestCase {

    // MARK: - Items + filter

    /// Pinned unfiltered order: group-then-declaration, matching the reference
    /// shot's section order (Headings / Basic blocks / Advanced / Media). Grew
    /// from 5 to 16 commands in Phase 2 / BAK-251 — this pin is intentionally
    /// updated here (not "unmodified") because the grown list IS the feature.
    func test_items_unfiltered_allCommands_orderPinned() {
        XCTAssertEqual(SlashMenu.items(query: "").map(\.id), [
            "h1", "h2", "h3", "h4",
            "quote", "bullet", "numbered", "checklist", "paragraph", "codeblock", "divider",
            "table", "link", "subpage", "agent",
            "image",
        ])
    }
    func test_items_unfiltered_count_matchesGroupedSpec() {
        XCTAssertEqual(SlashMenu.items(query: "").count, 16)
    }
    func test_items_filter_caseInsensitive_titleContains() {
        // Word-prefix matching, not substring-contains: "he" must NOT leak
        // "Ask *the* agent" in via "the". It DOES legitimately match all four
        // Heading rows now — every title's first word is "Heading".
        XCTAssertEqual(SlashMenu.items(query: "he").map(\.id), ["h1", "h2", "h3", "h4"])
        XCTAssertEqual(SlashMenu.items(query: "AGE"), SlashMenu.items(query: "age"))
    }
    func test_items_filter_matchesAnyTitleWordPrefix() {
        XCTAssertEqual(SlashMenu.items(query: "age").map(\.id), ["agent"])
        XCTAssertEqual(SlashMenu.items(query: "note").map(\.id), ["link"])
        XCTAssertEqual(SlashMenu.items(query: "sub").map(\.id), ["subpage"])
    }
    func test_items_filter_matchesNewCommands_wordPrefix() {
        XCTAssertEqual(SlashMenu.items(query: "quo").map(\.id), ["quote"])
        XCTAssertEqual(SlashMenu.items(query: "bull").map(\.id), ["bullet"])
        XCTAssertEqual(SlashMenu.items(query: "numb").map(\.id), ["numbered"])
        XCTAssertEqual(SlashMenu.items(query: "check").map(\.id), ["checklist"])
        XCTAssertEqual(SlashMenu.items(query: "para").map(\.id), ["paragraph"])
        XCTAssertEqual(SlashMenu.items(query: "code").map(\.id), ["codeblock"])
        XCTAssertEqual(SlashMenu.items(query: "div").map(\.id), ["divider"])
        XCTAssertEqual(SlashMenu.items(query: "tab").map(\.id), ["table"])
        XCTAssertEqual(SlashMenu.items(query: "imag").map(\.id), ["image"])
    }
    func test_items_noMatch_isEmpty() {
        XCTAssertTrue(SlashMenu.items(query: "zzz").isEmpty)
    }

    // MARK: - Groups

    func test_items_everyCommand_hasExpectedGroup() {
        let byID = Dictionary(uniqueKeysWithValues: SlashMenu.items(query: "").map { ($0.id, $0.group) })
        XCTAssertEqual(byID["h1"], .headings)
        XCTAssertEqual(byID["h2"], .headings)
        XCTAssertEqual(byID["h3"], .headings)
        XCTAssertEqual(byID["h4"], .headings)
        XCTAssertEqual(byID["quote"], .basicBlocks)
        XCTAssertEqual(byID["bullet"], .basicBlocks)
        XCTAssertEqual(byID["numbered"], .basicBlocks)
        XCTAssertEqual(byID["checklist"], .basicBlocks)
        XCTAssertEqual(byID["paragraph"], .basicBlocks)
        XCTAssertEqual(byID["codeblock"], .basicBlocks)
        XCTAssertEqual(byID["divider"], .basicBlocks)
        XCTAssertEqual(byID["table"], .advanced)
        XCTAssertEqual(byID["link"], .advanced)
        XCTAssertEqual(byID["subpage"], .advanced)
        XCTAssertEqual(byID["agent"], .advanced)
        XCTAssertEqual(byID["image"], .media)
    }
    func test_filtering_flattensAcrossGroups_inDisplayOrder() {
        // "l" matches "Bullet List"/"Numbered List"/"Check List" (Basic blocks,
        // via the second title word) AND "Link to note" (Advanced, via the
        // first). Filtering must preserve the unfiltered group-then-declaration
        // order, not group results together or reorder by match position.
        XCTAssertEqual(SlashMenu.items(query: "l").map(\.id), ["bullet", "numbered", "checklist", "link"])
    }

    // MARK: - Trigger detection (unchanged surface)

    func test_activeQuery_onlyAtLineStart_noWhitespace() {
        XCTAssertEqual(SlashMenu.activeQuery(linePrefix: "/"), "")
        XCTAssertEqual(SlashMenu.activeQuery(linePrefix: "/hea"), "hea")
        XCTAssertNil(SlashMenu.activeQuery(linePrefix: "a /hea"))
        XCTAssertNil(SlashMenu.activeQuery(linePrefix: "/he a"))
        XCTAssertNil(SlashMenu.activeQuery(linePrefix: ""))
    }
    func test_activeQuery_leadingWhitespace_isNotATrigger() {
        // The line up to the caret must be EXACTLY "/" + query.
        XCTAssertNil(SlashMenu.activeQuery(linePrefix: " /he"))
        XCTAssertNil(SlashMenu.activeQuery(linePrefix: "\t/he"))
    }

    // MARK: - Insertions (byte-exact — the menu's only source-producing output)

    func test_insertion_headings_byteExact() {
        XCTAssertEqual(SlashMenu.insertion(for: .heading(1), noteTitle: nil).text, "# ")
        XCTAssertEqual(SlashMenu.insertion(for: .heading(2), noteTitle: nil).text, "## ")
        XCTAssertEqual(SlashMenu.insertion(for: .heading(3), noteTitle: nil).text, "### ")
        XCTAssertEqual(SlashMenu.insertion(for: .heading(4), noteTitle: nil).text, "#### ")
    }
    func test_insertion_headings_caretAtEnd() {
        XCTAssertEqual(SlashMenu.insertion(for: .heading(1), noteTitle: nil).caretOffset, 2)
        XCTAssertEqual(SlashMenu.insertion(for: .heading(2), noteTitle: nil).caretOffset, 3)
        XCTAssertEqual(SlashMenu.insertion(for: .heading(3), noteTitle: nil).caretOffset, 4)
        XCTAssertEqual(SlashMenu.insertion(for: .heading(4), noteTitle: nil).caretOffset, 5)
    }
    func test_insertion_quote_byteExact_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .quote, noteTitle: nil)
        XCTAssertEqual(ins.text, "> "); XCTAssertEqual(ins.caretOffset, 2)
    }
    func test_insertion_bulletList_byteExact_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .bulletList, noteTitle: nil)
        XCTAssertEqual(ins.text, "- "); XCTAssertEqual(ins.caretOffset, 2)
    }
    func test_insertion_numberedList_byteExact_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .numberedList, noteTitle: nil)
        XCTAssertEqual(ins.text, "1. "); XCTAssertEqual(ins.caretOffset, 3)
    }
    func test_insertion_checkList_byteExact_caretAtEnd() {
        // Same template/caret the original "To-do" command always wrote.
        let ins = SlashMenu.insertion(for: .checkList, noteTitle: nil)
        XCTAssertEqual(ins.text, "- [ ] "); XCTAssertEqual(ins.caretOffset, 6)
    }
    func test_insertion_paragraph_isEmpty_dismissesToPlainText() {
        let ins = SlashMenu.insertion(for: .paragraph, noteTitle: nil)
        XCTAssertEqual(ins.text, ""); XCTAssertEqual(ins.caretOffset, 0)
    }
    func test_insertion_codeBlock_byteExact_caretInsideFence() {
        let ins = SlashMenu.insertion(for: .codeBlock, noteTitle: nil)
        XCTAssertEqual(ins.text, "```\n\n```")
        // Caret lands right after the opening fence's newline — the blank
        // interior line — not at the template's end.
        XCTAssertEqual(ins.caretOffset, 4)
    }
    func test_insertion_divider_byteExact_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .divider, noteTitle: nil)
        XCTAssertEqual(ins.text, "---\n"); XCTAssertEqual(ins.caretOffset, 4)
    }
    func test_insertion_table_byteExact_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .table, noteTitle: nil)
        XCTAssertEqual(ins.text, "| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |\n")
        XCTAssertEqual(ins.caretOffset, (ins.text as NSString).length)
    }
    func test_insertion_image_byteExact_caretInUrlSlot() {
        let ins = SlashMenu.insertion(for: .image, noteTitle: nil)
        XCTAssertEqual(ins.text, "![]()")
        // Between "(" and ")" — the url slot.
        XCTAssertEqual(ins.caretOffset, 4)
    }
    func test_insertion_linkToNote_caretInsideBrackets() {
        let ins = SlashMenu.insertion(for: .linkToNote, noteTitle: nil)
        XCTAssertEqual(ins.text, "[[]]"); XCTAssertEqual(ins.caretOffset, 2)
    }
    func test_insertion_linkToNote_withTitle_interpolates_caretAtEnd() {
        let ins = SlashMenu.insertion(for: .linkToNote, noteTitle: "Setup")
        XCTAssertEqual(ins.text, "[[Setup]]"); XCTAssertEqual(ins.caretOffset, 9)
    }
    func test_insertion_subpage_interpolatesTitle() {
        XCTAssertEqual(SlashMenu.insertion(for: .subpage, noteTitle: "New page").text, "[[New page]]\n")
    }
    func test_insertion_subpage_caretAfterNewline_utf16() {
        let ins = SlashMenu.insertion(for: .subpage, noteTitle: "New page")
        XCTAssertEqual(ins.caretOffset, ("[[New page]]\n" as NSString).length)
        // Non-BMP title: caret offset counts UTF-16 units, not characters.
        let emoji = SlashMenu.insertion(for: .subpage, noteTitle: "🗒 Plan")
        XCTAssertEqual(emoji.text, "[[🗒 Plan]]\n")
        XCTAssertEqual(emoji.caretOffset, ("[[🗒 Plan]]\n" as NSString).length)
    }
    func test_insertion_subpage_nilOrEmptyTitle_fallsBackUntitled() {
        // Mirrors NoteCreation's empty-title fallback so link and file agree.
        XCTAssertEqual(SlashMenu.insertion(for: .subpage, noteTitle: nil).text, "[[Untitled]]\n")
        XCTAssertEqual(SlashMenu.insertion(for: .subpage, noteTitle: "").text, "[[Untitled]]\n")
    }
    func test_insertion_askAgent_isVaultReadableCallout() {
        XCTAssertEqual(SlashMenu.insertion(for: .askAgent, noteTitle: nil).text, "> [!agent] ")
    }

    // MARK: - Round-trip guard (new templates parse cleanly through NoteDecoration)

    /// Every new (Phase 2 / BAK-251) multi-line/structural template must satisfy
    /// `NoteDecoration.blocks(_:)`'s lossless-reassembly guarantee — the same
    /// property `NoteDecorationTests.assertPartitionLossless` pins for arbitrary
    /// vault content, checked here for exactly what this menu writes.
    private func assertRoundTrips(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = source as NSString
        let blocks = NoteDecoration.blocks(source)
        let joined = blocks.map { ns.substring(with: $0.range) }.joined()
        XCTAssertEqual(joined, source, file: file, line: line)
    }

    func test_insertion_divider_roundTrips_asDividerBlock() {
        let text = SlashMenu.insertion(for: .divider, noteTitle: nil).text
        assertRoundTrips(text)
        let blocks = NoteDecoration.blocks(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), .divider)
    }
    func test_insertion_table_roundTrips_asTableBlock() {
        let text = SlashMenu.insertion(for: .table, noteTitle: nil).text
        assertRoundTrips(text)
        let blocks = NoteDecoration.blocks(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), .table)
    }
    func test_insertion_image_roundTrips_asImageBlock() {
        let text = SlashMenu.insertion(for: .image, noteTitle: nil).text
        assertRoundTrips(text)
        let blocks = NoteDecoration.blocks(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), .image)
    }
    func test_insertion_codeBlock_roundTrips_asCodeBlock() {
        let text = SlashMenu.insertion(for: .codeBlock, noteTitle: nil).text
        assertRoundTrips(text)
        let blocks = NoteDecoration.blocks(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), .codeBlock)
    }
    func test_insertion_headings_roundTrip_andClassifyAtInsertedLevel() {
        for level in 1...4 {
            let text = SlashMenu.insertion(for: .heading(level), noteTitle: nil).text + "Title"
            assertRoundTrips(text)
            let blocks = NoteDecoration.blocks(text)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), .heading(level))
        }
    }
    func test_insertion_quote_bulletList_numberedList_checkList_roundTrip() {
        let fixtures: [(SlashCommand.Kind, BlockKind)] = [
            (.quote, .quote), (.bulletList, .bulletList),
            (.numberedList, .numberedList), (.checkList, .todoList),
        ]
        for (kind, expected) in fixtures {
            let text = SlashMenu.insertion(for: kind, noteTitle: nil).text + "content"
            assertRoundTrips(text)
            let blocks = NoteDecoration.blocks(text)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(NoteDecoration.blockKind(text, of: blocks[0]), expected)
        }
    }
}
