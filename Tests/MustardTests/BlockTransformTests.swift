import XCTest
@testable import MustardKit

/// `BlockTransform` (Craft menus spec, Phase 3 / BAK-252): "turn into" +
/// Duplicate/Delete/Move up/Move down as pure splices. Mirrors
/// `BlockReorderTests`' byte-pinned style — exact expected strings, including
/// newline handling at document edges — plus a round-trip matrix over every
/// (source-kind, target-kind) pair `turnInto` supports.
final class BlockTransformTests: XCTestCase {

    private typealias Block = NoteDecoration.Block

    /// The first (only, for these single-block fixtures) block of `source`.
    private func firstBlock(_ source: String) -> Block {
        NoteDecoration.blocks(source)[0]
    }

    // MARK: - Frontmatter: no menu at all

    func test_allFourOperations_returnNil_forFrontmatterBlock() {
        let source = "---\ntitle: x\n---\nbody"
        let fm = NoteDecoration.blocks(source)[0]
        XCTAssertTrue(fm.isFrontmatter)
        XCTAssertNil(BlockTransform.turnInto(source, block: fm, target: .paragraph))
        XCTAssertNil(BlockTransform.duplicate(source, block: fm))
        XCTAssertNil(BlockTransform.delete(source, block: fm))
        XCTAssertNil(BlockTransform.moveUp(source, block: fm))
        XCTAssertNil(BlockTransform.moveDown(source, block: fm))
    }

    // MARK: - turnInto: divider excluded as SOURCE

    func test_turnInto_dividerSource_excluded_returnsNil() {
        let source = "---\n\ntext\n"
        let divider = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: divider), .divider)
        for target in BlockTransform.menuTargets {
            XCTAssertNil(BlockTransform.turnInto(source, block: divider, target: target))
        }
    }

    // MARK: - turnInto: non-menu targets excluded

    func test_turnInto_nonMenuTarget_returnsNil() {
        let source = "plain text\n"
        let block = firstBlock(source)
        for target: BlockKind in [.divider, .table, .image, .subpage] {
            XCTAssertNil(BlockTransform.turnInto(source, block: block, target: target))
        }
    }

    // MARK: - turnInto: byte-pinned representative conversions

    func test_turnInto_paragraphToHeading2_exactBytes() {
        let source = "hello world\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .heading(2))
        XCTAssertEqual(result?.source, "## hello world\n")
        XCTAssertEqual(result?.selection, NSRange(location: 3, length: 0))
    }

    func test_turnInto_headingToParagraph_stripsPrefix() {
        let source = "## hello world\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)
        XCTAssertEqual(result?.source, "hello world\n")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 0))
    }

    func test_turnInto_paragraphToQuote_addsPrefix() {
        let source = "hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .quote)
        XCTAssertEqual(result?.source, "> hello\n")
    }

    func test_turnInto_quoteToBulletList_swapsMarker() {
        let source = "> hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .bulletList)
        XCTAssertEqual(result?.source, "- hello\n")
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func test_turnInto_bulletListToNumberedList_swapsMarker() {
        let source = "- hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .numberedList)
        XCTAssertEqual(result?.source, "1. hello\n")
    }

    func test_turnInto_bulletListToTodoList_addsCheckbox() {
        let source = "- hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .todoList)
        XCTAssertEqual(result?.source, "- [ ] hello\n")
    }

    func test_turnInto_todoListToBulletList_stripsCheckbox() {
        let source = "- [ ] hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .bulletList)
        XCTAssertEqual(result?.source, "- hello\n")
    }

    func test_turnInto_checkedTodoListToBulletList_stripsCheckboxAndMark() {
        let source = "- [x] done\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .bulletList)
        XCTAssertEqual(result?.source, "- done\n")
    }

    func test_turnInto_bareTodoMarker_noTrailingText_stripsToEmpty() {
        let source = "- [ ]\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .bulletList)
        XCTAssertEqual(result?.source, "- \n")
    }

    func test_turnInto_paragraphToCodeBlock_wrapsFences() {
        let source = "hello\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .codeBlock)
        XCTAssertEqual(result?.source, "```\nhello\n```\n")
        XCTAssertEqual(result?.selection, NSRange(location: 4, length: 0))
    }

    func test_turnInto_codeBlockToParagraph_unwrapsFences_innerContentUntouched() {
        let source = "```\nhello\n```\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)
        XCTAssertEqual(result?.source, "hello\n")
    }

    func test_turnInto_codeBlockWithLanguageTag_unwraps_tagDropped() {
        let source = "```swift\nlet x = 1\n```\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)
        XCTAssertEqual(result?.source, "let x = 1\n")
    }

    func test_turnInto_unterminatedCodeBlock_interiorRunsToEnd() {
        let source = "```\nline one\nline two"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .bulletList)
        XCTAssertEqual(result?.source, "- line one\n- line two\n")
    }

    func test_turnInto_emptyCodeBlock_noInterior_targetGetsEmptyLine() {
        let source = "```\n```\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)
        XCTAssertEqual(result?.source, "\n")
    }

    // MARK: - turnInto: lossy fallback (table)

    func test_turnInto_tableToHeading_lossyFallback_cellsAsPlainText_neverMalformed() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .heading(1))
        // Separator row dropped (no content); data rows' cells joined by " ".
        XCTAssertEqual(result?.source, "# a b\n# 1 2\n")
        // Round-trip: every re-partitioned line classifies as the target kind.
        let reparsed = NoteDecoration.blocks(result!.source)
        XCTAssertEqual(reparsed.map { NoteDecoration.blockKind(result!.source, of: $0) },
                       [.heading(1), .heading(1)])
    }

    /// The bug this regression guards: if the fallback kept the raw `| a | b |`
    /// bytes, a `.paragraph` target (which adds no prefix) would reproduce a
    /// pipe-bearing multi-row block with a separator row — which
    /// `NoteDecoration.blockKind` would then re-classify as `.table`, not
    /// `.paragraph`, silently defeating the conversion the user asked for.
    func test_turnInto_tableToParagraph_doesNotRoundTripBackToTable() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)!
        // "a b\n1 2\n" — two consecutive plain lines merge into ONE paragraph
        // block (NoteDecoration's own grouping rule); the point of this
        // regression is that it's `.paragraph`, not `.table`, whatever the
        // block count.
        let reparsed = NoteDecoration.blocks(result.source)
        XCTAssertEqual(reparsed.map { NoteDecoration.blockKind(result.source, of: $0) }, [.paragraph])
    }

    // MARK: - turnInto: image/subpage as SOURCE extract plain text (not the raw atom)

    func test_turnInto_imageAsSource_extractsAltText() {
        let source = "![alt](url)\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .heading(1))
        XCTAssertEqual(result?.source, "# alt\n")
    }

    func test_turnInto_subpageAsSource_extractsLinkTitle() {
        let source = "[[Target]]\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .quote)
        XCTAssertEqual(result?.source, "> Target\n")
    }

    /// Same regression as the table case, for image/subpage → `.paragraph`.
    func test_turnInto_imageToParagraph_doesNotRoundTripBackToImage() {
        let source = "![alt](url)\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)!
        XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstBlock(result.source)), .paragraph)
    }

    func test_turnInto_subpageToParagraph_doesNotRoundTripBackToSubpage() {
        let source = "[[Target]]\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)!
        XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstBlock(result.source)), .paragraph)
    }

    // MARK: - turnInto: tail (trailing blank separator) preserved verbatim

    func test_turnInto_preservesTrailingBlankTail_untouched() {
        let source = "# H\n\ntail\n"
        let block = NoteDecoration.blocks(source)[0]
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .heading(1))
        let result = BlockTransform.turnInto(source, block: block, target: .paragraph)
        XCTAssertEqual(result?.source, "H\n\ntail\n")
    }

    // MARK: - turnInto: multi-line paragraph → per-line explosion

    func test_turnInto_multiLineParagraphToBulletList_eachLineBecomesOneItem() {
        let source = "line one\nline two\nline three\n"
        let block = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .paragraph)
        let result = BlockTransform.turnInto(source, block: block, target: .bulletList)
        XCTAssertEqual(result?.source, "- line one\n- line two\n- line three\n")

        let reparsed = NoteDecoration.blocks(result!.source)
        XCTAssertEqual(reparsed.count, 3)
        XCTAssertEqual(reparsed.map { NoteDecoration.blockKind(result!.source, of: $0) },
                       [.bulletList, .bulletList, .bulletList])
    }

    func test_turnInto_multiLineParagraphToNumberedList_sequentialNumbering() {
        let source = "a\nb\nc\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .numberedList)
        XCTAssertEqual(result?.source, "1. a\n2. b\n3. c\n")
    }

    func test_turnInto_multiLineParagraphToHeading_eachLineOwnHeading() {
        let source = "a\nb\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .heading(3))
        XCTAssertEqual(result?.source, "### a\n### b\n")
    }

    func test_turnInto_codeBlockMultiInteriorLinesToQuote_perLine() {
        let source = "```\nfirst\nsecond\n```\n"
        let block = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .codeBlock)
        let result = BlockTransform.turnInto(source, block: block, target: .quote)
        XCTAssertEqual(result?.source, "> first\n> second\n")

        let reparsed = NoteDecoration.blocks(result!.source)
        XCTAssertEqual(reparsed.map { NoteDecoration.blockKind(result!.source, of: $0) }, [.quote, .quote])
    }

    // MARK: - turnInto: multi-line PARAGRAPH → codeBlock wraps ALL lines in ONE fence

    func test_turnInto_multiLineParagraphToCodeBlock_singleFenceWrapsAllLines() {
        let source = "a\nb\nc\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .codeBlock)
        XCTAssertEqual(result?.source, "```\na\nb\nc\n```\n")
    }

    // MARK: - turnInto: round-trip matrix over every supported (source, target) pair

    /// One single-content-line fixture per testable source `BlockKind` (divider
    /// excluded — it has no `turnInto` source path at all, covered above).
    private func sourceFixtures() -> [(kind: BlockKind, source: String)] {
        [
            (.paragraph, "hello\n"),
            (.heading(2), "## hello\n"),
            (.quote, "> hello\n"),
            (.bulletList, "- hello\n"),
            (.numberedList, "1. hello\n"),
            (.todoList, "- [ ] hello\n"),
            (.codeBlock, "```\nhello\n```\n"),
            (.table, "| a | b |\n|---|---|\n"),
            (.image, "![alt](url)\n"),
            (.subpage, "[[Target]]\n"),
        ]
    }

    /// Matrix: every source fixture × every menu target. `turnInto` must
    /// succeed and the re-partitioned block(s) starting at the original offset
    /// must classify as `target` — the round-trip guard the spec requires,
    /// extended to every pair this phase supports.
    func test_roundTripMatrix_everySourceKindTimesEveryMenuTarget() {
        for fixture in sourceFixtures() {
            let block = firstBlock(fixture.source)
            XCTAssertEqual(NoteDecoration.blockKind(fixture.source, of: block), fixture.kind,
                            "fixture setup wrong for \(fixture.kind)")
            for target in BlockTransform.menuTargets {
                guard let result = BlockTransform.turnInto(fixture.source, block: block, target: target) else {
                    XCTFail("turnInto returned nil for \(fixture.kind) -> \(target)")
                    continue
                }
                let reparsed = NoteDecoration.blocks(result.source)
                guard let firstResultBlock = reparsed.first(where: { $0.range.location == block.range.location }) else {
                    XCTFail("no re-partitioned block at original offset for \(fixture.kind) -> \(target)")
                    continue
                }
                XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstResultBlock), target,
                               "\(fixture.kind) -> \(target) produced \(result.source.debugDescription)")
                // Never malformed: the round-trip re-parse must be lossless at
                // the NSString level (every UTF-16 unit still classifies into
                // SOME block — `blocks` is a total partition by construction).
                let totalLength = reparsed.reduce(0) { $0 + $1.range.length }
                XCTAssertEqual(totalLength, (result.source as NSString).length,
                               "\(fixture.kind) -> \(target) broke the total partition")
            }
        }
    }

    // MARK: - turnInto: classifier-echo regressions (BLOCKING review finding)

    /// Reviewer repro #1: a heading whose stripped content happens to start
    /// with a quote marker must NOT silently reclassify as `.quote` once
    /// rendered under a `.paragraph` target — it must come back byte-escaped
    /// so it stays honest `.paragraph` text.
    func test_turnInto_headingContentLooksLikeQuote_escapesOnParagraphTarget() {
        let source = "# > note\n"
        let block = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .heading(1))
        let result = BlockTransform.turnInto(source, block: block, target: .paragraph)!
        XCTAssertEqual(result.source, "\\> note\n")
        XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstBlock(result.source)), .paragraph)
    }

    /// Reviewer repro #2: a quote whose stripped content happens to start
    /// with a bullet marker must NOT silently reclassify as `.bulletList`.
    func test_turnInto_quoteContentLooksLikeBullet_escapesOnParagraphTarget() {
        let source = "> - item\n"
        let block = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .quote)
        let result = BlockTransform.turnInto(source, block: block, target: .paragraph)!
        XCTAssertEqual(result.source, "\\- item\n")
        XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstBlock(result.source)), .paragraph)
    }

    // MARK: - turnInto: adversarial round-trip matrix (every echo-prone shape)

    /// Content shaped like ANOTHER kind's marker — the exact bug class the
    /// reviewer found. `insertEscapeBeforeMarker`'s job (see
    /// `BlockTransform.escapeIfWouldMisclassify`) is to keep every one of
    /// these from reclassifying under a `.paragraph` target; every other
    /// target must stay immune because it always prepends its OWN marker.
    private static let adversarialPayloads = [
        "# fake heading",
        "> fake quote",
        "- fake bullet",
        "1. fake ordered",
        "---",
    ]

    /// One single-line source fixture per adversarial payload, for every
    /// source `BlockKind` whose stripped content can actually BECOME that
    /// payload verbatim (paragraph is excluded: `NoteDecoration.blocks`
    /// can't produce a paragraph line that itself classifies as a marker
    /// line — it would already have started its own block).
    private func adversarialSourceFixtures(payload: String) -> [(kind: BlockKind, source: String)] {
        [
            (.heading(2), "## \(payload)\n"),
            (.quote, "> \(payload)\n"),
            (.bulletList, "- \(payload)\n"),
            (.numberedList, "1. \(payload)\n"),
            (.todoList, "- [ ] \(payload)\n"),
            (.codeBlock, "```\n\(payload)\n```\n"),
        ]
    }

    func test_roundTripMatrix_adversarialContent_everySingleLineSourceKindTimesEveryTarget() {
        for payload in Self.adversarialPayloads {
            for fixture in adversarialSourceFixtures(payload: payload) {
                let block = firstBlock(fixture.source)
                XCTAssertEqual(NoteDecoration.blockKind(fixture.source, of: block), fixture.kind,
                                "fixture setup wrong for \(fixture.kind) / \(payload)")
                for target in BlockTransform.menuTargets {
                    guard let result = BlockTransform.turnInto(fixture.source, block: block, target: target) else {
                        XCTFail("turnInto returned nil for \(fixture.kind) -> \(target), payload \(payload)")
                        continue
                    }
                    let reparsed = NoteDecoration.blocks(result.source)
                    guard let firstResultBlock = reparsed.first(where: { $0.range.location == block.range.location }) else {
                        XCTFail("no re-partitioned block at original offset for \(fixture.kind) -> \(target), payload \(payload)")
                        continue
                    }
                    XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstResultBlock), target,
                                   "\(fixture.kind) -> \(target) echoed on payload \(payload.debugDescription): \(result.source.debugDescription)")
                    let totalLength = reparsed.reduce(0) { $0 + $1.range.length }
                    XCTAssertEqual(totalLength, (result.source as NSString).length,
                                   "\(fixture.kind) -> \(target) broke the total partition on payload \(payload.debugDescription)")
                }
            }
        }
    }

    /// Table/image/subpage sources also route adversarial content through
    /// `.paragraph` — same matrix, smaller fixture set since each of these
    /// kinds needs its own wrapper syntax. Subpage additionally can't carry a
    /// "#" (its title-validity rule forbids it), so it skips that one payload.
    func test_roundTripMatrix_adversarialContent_tableImageSubpageSources() {
        for payload in Self.adversarialPayloads {
            var fixtures: [(kind: BlockKind, source: String)] = [
                (.table, "| \(payload) | b |\n|---|---|\n"),
                (.image, "![\(payload)](url)\n"),
            ]
            if !payload.contains("#") {
                fixtures.append((.subpage, "[[\(payload)]]\n"))
            }
            for fixture in fixtures {
                let block = firstBlock(fixture.source)
                XCTAssertEqual(NoteDecoration.blockKind(fixture.source, of: block), fixture.kind,
                                "fixture setup wrong for \(fixture.kind) / \(payload)")
                for target in BlockTransform.menuTargets {
                    guard let result = BlockTransform.turnInto(fixture.source, block: block, target: target) else {
                        XCTFail("turnInto returned nil for \(fixture.kind) -> \(target), payload \(payload)")
                        continue
                    }
                    let reparsed = NoteDecoration.blocks(result.source)
                    guard let firstResultBlock = reparsed.first(where: { $0.range.location == block.range.location }) else {
                        XCTFail("no re-partitioned block at original offset for \(fixture.kind) -> \(target), payload \(payload)")
                        continue
                    }
                    XCTAssertEqual(NoteDecoration.blockKind(result.source, of: firstResultBlock), target,
                                   "\(fixture.kind) -> \(target) echoed on payload \(payload.debugDescription): \(result.source.debugDescription)")
                }
            }
        }
    }

    // MARK: - turnInto: fence-in-fence (codeBlock target audit finding)

    /// A table cell's plain-text extraction can legitimately produce a
    /// content line that STARTS WITH a fence marker (`tablePlainTextRows`
    /// joins cells with spaces, so a cell literally containing "```" survives
    /// into the joined line) — unlike every other source kind, this one CAN
    /// smuggle a fence-shaped line into a `.codeBlock` target's single
    /// wrapping fence, prematurely closing it on re-parse. Must come back
    /// escaped so the outer fence still round-trips to exactly one
    /// `.codeBlock`.
    func test_turnInto_tableCellContainsFenceMarker_codeBlockTarget_innerFenceEscaped() {
        let source = "| ``` | b |\n|---|---|\n"
        let block = firstBlock(source)
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .table)
        let result = BlockTransform.turnInto(source, block: block, target: .codeBlock)!
        // The inner fence-shaped line must be escaped, not raw, so it can't
        // be mistaken for the block's own closing delimiter.
        XCTAssertFalse(result.source.contains("\n``` b\n"))
        let reparsed = NoteDecoration.blocks(result.source)
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(NoteDecoration.blockKind(result.source, of: reparsed[0]), .codeBlock)
    }

    /// Same fence-in-fence hazard, `.paragraph` target: the smuggled line
    /// must escape just like any other echo-prone content.
    func test_turnInto_tableCellContainsFenceMarker_paragraphTarget_escaped() {
        let source = "| ``` | b |\n|---|---|\n"
        let result = BlockTransform.turnInto(source, block: firstBlock(source), target: .paragraph)!
        let reparsed = NoteDecoration.blocks(result.source)
        XCTAssertEqual(reparsed.map { NoteDecoration.blockKind(result.source, of: $0) }, [.paragraph])
    }

    // MARK: - turnInto: block immediately after frontmatter (Fix 3)

    /// Byte-pinned: the block right after a frontmatter block is a normal,
    /// fully-operable content block — only the frontmatter block itself is
    /// exempt. Exercises both `turnInto` and `delete` on it.
    func test_turnInto_blockImmediatelyAfterFrontmatter_exactBytes() {
        let source = "---\ntitle: x\n---\n# heading\n"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertTrue(blocks[0].isFrontmatter)
        let headingBlock = blocks[1]
        XCTAssertEqual(NoteDecoration.blockKind(source, of: headingBlock), .heading(1))

        let result = BlockTransform.turnInto(source, block: headingBlock, target: .paragraph)
        XCTAssertEqual(result?.source, "---\ntitle: x\n---\nheading\n")
        XCTAssertEqual(result?.selection, NSRange(location: headingBlock.range.location, length: 0))
    }

    func test_delete_blockImmediatelyAfterFrontmatter_exactBytes() {
        let source = "---\ntitle: x\n---\n# heading\n"
        let blocks = NoteDecoration.blocks(source)
        let headingBlock = blocks[1]

        let result = BlockTransform.delete(source, block: headingBlock)
        XCTAssertEqual(result?.source, "---\ntitle: x\n---\n")
        XCTAssertEqual(result?.selection, NSRange(location: headingBlock.range.location, length: 0))
    }

    // MARK: - Duplicate

    func test_duplicate_paragraph_exactBytes() {
        let source = "para\n\nsecond\n"
        let block = firstBlock(source)
        let result = BlockTransform.duplicate(source, block: block)
        XCTAssertEqual(result?.source, "para\n\npara\n\nsecond\n")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
    }

    func test_duplicate_lastBlockNoTrailingNewline_gainsSeparatorNoFusion() {
        let source = "first\n\ntail no newline"
        let blocks = NoteDecoration.blocks(source)
        let tailBlock = blocks[1]
        let result = BlockTransform.duplicate(source, block: tailBlock)
        XCTAssertEqual(result?.source, "first\n\ntail no newline\ntail no newline")
    }

    func test_duplicate_frontmatter_returnsNil() {
        let source = "---\ntitle: x\n---\nbody"
        let fm = NoteDecoration.blocks(source)[0]
        XCTAssertNil(BlockTransform.duplicate(source, block: fm))
    }

    // MARK: - Delete

    func test_delete_middleBlock_exactBytes_selectionAtNextBlockStart() {
        let source = "# H\n\npara\n\ntail\n"
        let blocks = NoteDecoration.blocks(source)
        let paraBlock = blocks[1]
        let result = BlockTransform.delete(source, block: paraBlock)
        XCTAssertEqual(result?.source, "# H\n\ntail\n")
        XCTAssertEqual(result?.selection, NSRange(location: paraBlock.range.location, length: 0))
    }

    func test_delete_lastBlock_selectionCollapsesToPreviousBlockEnd() {
        let source = "# H\n\npara\n"
        let blocks = NoteDecoration.blocks(source)
        let lastBlock = blocks[1]
        let result = BlockTransform.delete(source, block: lastBlock)
        XCTAssertEqual(result?.source, "# H\n\n")
        XCTAssertEqual(result?.selection, NSRange(location: lastBlock.range.location, length: 0))
    }

    func test_delete_onlyBlock_emptiesDocument_selectionAtZero() {
        let source = "solo\n"
        let result = BlockTransform.delete(source, block: firstBlock(source))
        XCTAssertEqual(result?.source, "")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 0))
    }

    func test_delete_frontmatter_returnsNil() {
        let source = "---\ntitle: x\n---\nbody"
        let fm = NoteDecoration.blocks(source)[0]
        XCTAssertNil(BlockTransform.delete(source, block: fm))
    }

    // MARK: - Move up / Move down (delegates to BlockReorder.move)

    func test_moveUp_middleBlock_matchesBlockReorderMove() {
        let source = "# H\n\nfirst\n\nsecond\n"
        let blocks = NoteDecoration.blocks(source)
        let secondBlock = blocks[2]   // moveable index 2 ("# H"=0, "first"=1, "second"=2)
        let result = BlockTransform.moveUp(source, block: secondBlock)
        XCTAssertEqual(result?.source, BlockReorder.move(source, from: 2, to: 1))
        XCTAssertEqual(result?.source, "# H\n\nsecond\n\nfirst\n")
    }

    func test_moveDown_middleBlock_matchesBlockReorderMove() {
        let source = "# H\n\nfirst\n\nsecond\n"
        let blocks = NoteDecoration.blocks(source)
        let headingBlock = blocks[0]   // moveable index 0
        let result = BlockTransform.moveDown(source, block: headingBlock)
        XCTAssertEqual(result?.source, BlockReorder.move(source, from: 0, to: 1))
    }

    func test_moveUp_alreadyFirst_returnsNil() {
        let source = "first\n\nsecond\n"
        let firstMoveable = NoteDecoration.blocks(source)[0]
        XCTAssertNil(BlockTransform.moveUp(source, block: firstMoveable))
    }

    func test_moveDown_alreadyLast_returnsNil() {
        let source = "first\n\nsecond\n"
        let lastMoveable = NoteDecoration.blocks(source)[1]
        XCTAssertNil(BlockTransform.moveDown(source, block: lastMoveable))
    }

    func test_moveUp_frontmatter_returnsNil() {
        let source = "---\ntitle: x\n---\nbody"
        let fm = NoteDecoration.blocks(source)[0]
        XCTAssertNil(BlockTransform.moveUp(source, block: fm))
    }

    func test_moveUp_selectionLandsAtMovedBlockNewStart() {
        let source = "# H\n\nfirst\n\nsecond\n"
        let blocks = NoteDecoration.blocks(source)
        let secondBlock = blocks[2]   // moveable index 2, moves up to index 1
        let result = BlockTransform.moveUp(source, block: secondBlock)!
        XCTAssertEqual(result.source, "# H\n\nsecond\n\nfirst\n")
        // "second" is now moveable[1] (after "# H", before the displaced "first").
        let newMoveable = NoteDecoration.blocks(result.source).filter { !$0.isFrontmatter }
        XCTAssertEqual(result.selection, NSRange(location: newMoveable[1].range.location, length: 0))
    }
}
