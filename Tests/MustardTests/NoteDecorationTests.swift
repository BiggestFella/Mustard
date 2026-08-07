import XCTest
@testable import MustardKit

final class NoteDecorationTests: XCTestCase {

    // MARK: - Blocks: the round-trip guard

    /// THE round-trip guard (spec hard constraint): the partition must reassemble
    /// the source byte-for-byte for every fixture — including grammar we don't style.
    private func assertPartitionLossless(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = source as NSString
        let blocks = NoteDecoration.blocks(source)
        let joined = blocks.map { ns.substring(with: $0.range) }.joined()
        XCTAssertEqual(joined, source, file: file, line: line)
        // Contiguous + in order:
        var cursor = 0
        for block in blocks {
            XCTAssertEqual(block.range.location, cursor, file: file, line: line)
            cursor += block.range.length
        }
        XCTAssertEqual(cursor, ns.length, file: file, line: line)
    }

    func test_blocks_partition_reassemblesSource_exactly() {
        assertPartitionLossless("---\ntitle: X\n---\n\n# H\n\npara one\npara two\n\n- a\n- b\n\n```\ncode [[x]]\n```\n")
    }
    func test_blocks_unsupportedGrammar_staysRaw_neverNormalized() {
        assertPartitionLossless("| a | b |\n|---|---|\n| 1 | 2 |\n\nSetext\n======\n\n<div>html</div>")
    }
    func test_blocks_crlf_and_noTrailingNewline_lossless() {
        assertPartitionLossless("# H\r\n\r\npara\r\ntail without newline")
    }
    func test_blocks_emptySource_isEmpty() {
        XCTAssertEqual(NoteDecoration.blocks(""), [])
    }
    func test_blocks_fixtureBattery_lossless() {
        for source in [
            "- a\n  - nested\n    - deeper\n- b\n",
            "> one\n> two\n\n> three",
            "---\n\n***\n\ntext\n---\n",
            "```\nunterminated fence\n\nstill code",
            "\n\nleading blanks\n",
            "\n\n\n",
            "---",
            "---\r\ntitle: x\r\n---\r\nbody\r\n",
            "***",
            "# H\n#not-a-heading\n####### seven\n1) not ordered\n",
        ] {
            assertPartitionLossless(source)
        }
    }
    func test_blocks_frontmatterFlagged_andUnterminatedIsNotFrontmatter() {
        XCTAssertTrue(NoteDecoration.blocks("---\ntitle: x\n---\nbody")[0].isFrontmatter)
        XCTAssertFalse(NoteDecoration.blocks("---\ntitle: x\nno end")[0].isFrontmatter)
    }
    func test_blocks_trailingBlankLines_attachToPrecedingBlock() {
        let source = "# H\n\n\npara"
        let ns = source as NSString
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(ns.substring(with: blocks[0].range), "# H\n\n\n")
    }
    func test_blocks_fenceSwallowsBlankLinesAndMarkers_untilClose() {
        let blocks = NoteDecoration.blocks("```\n# not a heading\n\n---\n```\nafter")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].isFence)
    }
    func test_blocks_unterminatedFence_swallowsToEOF_flagged() {
        let blocks = NoteDecoration.blocks("```\ncode\n\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isFence)
        assertPartitionLossless("```\ncode\n\n")
    }
    func test_blocks_headingQuoteListRuleLines_oneBlockPerLine() {
        // Single-line block kinds never group; the two plain lines do.
        let blocks = NoteDecoration.blocks("# H\n> q\n- a\n1. b\n---\npara\npara2")
        XCTAssertEqual(blocks.count, 6)
        assertPartitionLossless("# H\n> q\n- a\n1. b\n---\npara\npara2")
    }
    func test_blocks_leadingBlankLines_formTheirOwnBlock() {
        let source = "\n\npara"
        let ns = source as NSString
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(ns.substring(with: blocks[0].range), "\n\n")
        XCTAssertFalse(blocks[0].isFrontmatter)
        XCTAssertFalse(blocks[0].isFence)
    }
    func test_blocks_frontmatter_crlf_detected() {
        // \r\n terminators are excluded from the raw line compare (one terminator),
        // so CRLF frontmatter is detected exactly as Frontmatter.parse detects it.
        let blocks = NoteDecoration.blocks("---\r\ntitle: x\r\n---\r\nbody")
        XCTAssertTrue(blocks[0].isFrontmatter)
        XCTAssertEqual(blocks.count, 2)
    }

    // MARK: - Spans

    private typealias Span = NoteDecoration.Span

    func test_spans_heading_marksHashesAsMarker_textAsHeading() {
        let spans = NoteDecoration.spans("## Two")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 3), kind: .marker)))   // "## "
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 3, length: 3), kind: .heading(level: 2))))
    }
    func test_spans_bold_italic_code_withMarkerRanges() {
        // "a **b** *i* `c`" — b at 4, i at 9, c at 13.
        let spans = NoteDecoration.spans("a **b** *i* `c`")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 4, length: 1), kind: .bold)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 2), kind: .marker)))    // leading **
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 9, length: 1), kind: .italic)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 13, length: 1), kind: .inlineCode)))
    }
    // MARK: - Strikethrough / highlight (Phase 4 / BAK-253 — new inline kinds)

    func test_spans_strikethrough_withMarkerRanges() {
        // "a ~~b~~ c" — content "b" at 5, markers "~~" at 2 and 6.
        let spans = NoteDecoration.spans("a ~~b~~ c")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 4, length: 1), kind: .strikethrough)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 2), kind: .marker)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 5, length: 2), kind: .marker)))
    }

    func test_spans_highlight_withMarkerRanges() {
        let spans = NoteDecoration.spans("a ==b== c")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 4, length: 1), kind: .highlight)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 2), kind: .marker)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 5, length: 2), kind: .marker)))
    }

    func test_spans_strikethrough_unmatched_producesNoSpan() {
        XCTAssertFalse(NoteDecoration.spans("~~not closed").contains { $0.kind == .strikethrough })
        XCTAssertFalse(NoteDecoration.spans("plain ~ tilde").contains { $0.kind == .strikethrough })
    }

    func test_spans_highlight_unmatched_producesNoSpan() {
        XCTAssertFalse(NoteDecoration.spans("==not closed").contains { $0.kind == .highlight })
        XCTAssertFalse(NoteDecoration.spans("plain = sign").contains { $0.kind == .highlight })
    }

    func test_spans_strikethroughAndHighlight_dontClaimCodeSpanOrFence() {
        XCTAssertFalse(NoteDecoration.spans("`~~x~~`").contains { $0.kind == .strikethrough })
        XCTAssertFalse(NoteDecoration.spans("```\n~~x~~\n==y==\n```\n").contains {
            $0.kind == .strikethrough || $0.kind == .highlight
        })
    }

    func test_markerVisibility_strikethroughAndHighlight_hideAndRevealLikeBoldItalic() {
        let source = "para ~~s~~ ==h==\n"
        let ns = source as NSString
        let hidden = NoteDecoration.markerVisibility(source, focusedRange: nil)
        let strikeFull = ns.range(of: "~~s~~")
        XCTAssertTrue(hidden.hidden.contains(NSRange(location: strikeFull.location, length: 2)))
        XCTAssertTrue(hidden.hidden.contains(NSRange(location: strikeFull.upperBound - 2, length: 2)))
        let highlightFull = ns.range(of: "==h==")
        XCTAssertTrue(hidden.hidden.contains(NSRange(location: highlightFull.location, length: 2)))
        XCTAssertTrue(hidden.hidden.contains(NSRange(location: highlightFull.upperBound - 2, length: 2)))

        let caret = ns.range(of: "para").location
        let revealed = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: caret, length: 0))
        XCTAssertTrue(revealed.revealed.contains(NSRange(location: strikeFull.location, length: 2)))
        XCTAssertTrue(revealed.revealed.contains(NSRange(location: highlightFull.location, length: 2)))
    }

    func test_spans_wikilink_labelAndMarkers_aliasHidesTarget() {
        // "[[Note|alias]]" → markers: "[[", "Note|", "]]"; label: "alias"
        let spans = NoteDecoration.spans("[[Note|alias]]")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 7, length: 5),
                                          kind: .wikilink(target: "Note", alias: "alias"))))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 2), kind: .marker)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 5), kind: .marker)))    // "Note|"
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 12, length: 2), kind: .marker)))
    }
    func test_spans_wikilink_anchorIsMarker() {
        // "[[Note#Sec]]" → label "Note", "#Sec" de-emphasized.
        let spans = NoteDecoration.spans("[[Note#Sec]]")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 4),
                                          kind: .wikilink(target: "Note", alias: nil))))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 6, length: 4), kind: .marker)))    // "#Sec"
    }
    func test_spans_embed_leadingBangInsideMarker() {
        // "![[Img]]" — the "!" is syntax, not label.
        let spans = NoteDecoration.spans("![[Img]]")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 3), kind: .marker)))    // "![["
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 3, length: 3),
                                          kind: .wikilink(target: "Img", alias: nil))))
    }
    func test_spans_noEmphasisInsideCodeSpan_orFence_orFrontmatter() {
        XCTAssertFalse(NoteDecoration.spans("`**x**`").contains { $0.kind == .bold })
        XCTAssertFalse(NoteDecoration.spans("```\n**x** [[L]]\n```").contains {
            $0.kind == .bold || $0.kind == .wikilink(target: "L", alias: nil)
        })
        XCTAssertFalse(NoteDecoration.spans("---\nnote: \"**x**\"\n---\n").contains { $0.kind == .bold })
    }
    func test_spans_wikilinkInsideInlineCode_staysRaw() {
        // Inline code is opaque, mirroring the fence rule one level down.
        let spans = NoteDecoration.spans("`[[L]]`")
        XCTAssertFalse(spans.contains { $0.kind == .wikilink(target: "L", alias: nil) })
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 1, length: 5), kind: .inlineCode)))
    }
    func test_spans_inBlock_matchesWholeDocumentSubset() {
        let source = "# H\n\npara **b**\n"
        let block = NoteDecoration.blocks(source)[1]
        XCTAssertEqual(NoteDecoration.spans(source, in: block),
                       NoteDecoration.spans(source).filter { block.range.contains($0.range.location) })
    }
    func test_spans_allRangesWithinBounds_neverOverlapContentKinds() {
        // Fixture battery: every span range fits in the source, and no two INLINE
        // content spans (bold/italic/code/wikilink) overlap. Line-level spans
        // (heading) deliberately cover their inline spans — layering, not overlap.
        func isInlineContent(_ kind: NoteDecoration.Kind) -> Bool {
            switch kind {
            case .bold, .italic, .inlineCode, .wikilink: return true
            default: return false
            }
        }
        for source in ["", "# H", "**a** *b* `c` [[w|x]]", "---\nt: v\n---\n# H\n```\nx\n```",
                       "- **a** [[L|l]] `x`\n> *q*"] {
            let ns = source as NSString
            let spans = NoteDecoration.spans(source)
            for span in spans {
                XCTAssertGreaterThanOrEqual(span.range.location, 0)
                XCTAssertLessThanOrEqual(span.range.upperBound, ns.length, "in \(source)")
            }
            let inline = spans.filter { isInlineContent($0.kind) }
            for (i, a) in inline.enumerated() {
                for b in inline.dropFirst(i + 1) {
                    XCTAssertEqual(NSIntersectionRange(a.range, b.range).length, 0,
                                   "\(a) overlaps \(b) in \(source)")
                }
            }
        }
    }
    func test_spans_listMarkers_bullet_ordered_quote_indent() {
        XCTAssertTrue(NoteDecoration.spans("- go [[Home]]").contains(
            Span(range: NSRange(location: 0, length: 2), kind: .listMarker)))
        XCTAssertTrue(NoteDecoration.spans("- go [[Home]]").contains(
            Span(range: NSRange(location: 7, length: 4), kind: .wikilink(target: "Home", alias: nil))))
        XCTAssertTrue(NoteDecoration.spans("1. first").contains(
            Span(range: NSRange(location: 0, length: 3), kind: .listMarker)))
        XCTAssertTrue(NoteDecoration.spans("> hi").contains(
            Span(range: NSRange(location: 0, length: 2), kind: .listMarker)))
        XCTAssertTrue(NoteDecoration.spans("  - a").contains(
            Span(range: NSRange(location: 0, length: 4), kind: .listMarker)))
    }
    func test_spans_fence_markerLinesAndCodeBlockInterior() {
        // "```swift\nlet a = 1\n```" — language tag rides in the marker line.
        let spans = NoteDecoration.spans("```swift\nlet a = 1\n```")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 8), kind: .marker)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 9, length: 10), kind: .codeBlock)))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 19, length: 3), kind: .marker)))
    }
    func test_spans_emptyFence_hasNoCodeBlockSpan() {
        XCTAssertFalse(NoteDecoration.spans("```\n```").contains { $0.kind == .codeBlock })
    }
    func test_spans_frontmatter_isOneSpanOverWholeBlock() {
        let source = "---\nt: v\n---\n\nbody"
        let spans = NoteDecoration.spans(source, in: NoteDecoration.blocks(source)[0])
        XCTAssertEqual(spans, [Span(range: NSRange(location: 0, length: 14), kind: .frontmatter)])
    }
    func test_spans_ruleLines_deemphasizedAsMarker() {
        // A lone "---" has no closing fence, so it's a rule, not frontmatter.
        XCTAssertEqual(NoteDecoration.spans("---"),
                       [Span(range: NSRange(location: 0, length: 3), kind: .marker)])
        XCTAssertEqual(NoteDecoration.spans("***"),
                       [Span(range: NSRange(location: 0, length: 3), kind: .marker)])
    }
    func test_spans_headingWithInlineContent_layersBoth() {
        let spans = NoteDecoration.spans("# About [[Home]]")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 14), kind: .heading(level: 1))))
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 10, length: 4),
                                          kind: .wikilink(target: "Home", alias: nil))))
    }
    func test_spans_unmatchedMarkers_produceNoSpans() {
        // Raw text, never guessed.
        XCTAssertEqual(NoteDecoration.spans("**a"), [])
        XCTAssertEqual(NoteDecoration.spans("`x"), [])
        XCTAssertEqual(NoteDecoration.spans("a ** b"), [])
        XCTAssertEqual(NoteDecoration.spans("***bolditalic***"), [])
    }
    func test_spans_underscoreEmphasis_notParsed() {
        XCTAssertEqual(NoteDecoration.spans("_x_ and __y__"), [])
    }
    func test_spans_emptySource_isEmpty() {
        XCTAssertEqual(NoteDecoration.spans(""), [])
    }

    // MARK: - Subpage cards (2b, Task 10 — additive span kind)

    private func isCard(_ kind: NoteDecoration.Kind) -> Bool {
        if case .subpageCard = kind { return true }
        return false
    }

    func test_spans_wikilinkAloneOnLine_isSubpageCard() {
        let spans = NoteDecoration.spans("[[Target]]")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 10),
                                          kind: .subpageCard(target: "Target"))))
        // Additive: the ordinary wikilink span (and its markers) remain — the
        // characters stay clickable text; the card is only drawn behind them.
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 2, length: 6),
                                          kind: .wikilink(target: "Target", alias: nil))))
    }
    func test_spans_subpageCard_coversLineContent_withSurroundingSpaces() {
        // "  [[T]]  \n" — trimmed content is exactly one link; the card span
        // covers the line's content range (terminator excluded).
        let spans = NoteDecoration.spans("  [[T]]  \nafter")
        XCTAssertTrue(spans.contains(Span(range: NSRange(location: 0, length: 9),
                                          kind: .subpageCard(target: "T"))))
    }
    func test_spans_wikilinkWithSurroundingText_isNotCard() {
        XCTAssertFalse(NoteDecoration.spans("see [[Target]]").contains { isCard($0.kind) })
        XCTAssertFalse(NoteDecoration.spans("[[Target]] trailing").contains { isCard($0.kind) })
    }
    func test_spans_aliasAnchorEmbedOrListLine_isNotCard() {
        for source in ["[[T|alias]]", "[[T#anchor]]", "![[T]]", "- [[T]]",
                       "[[a]] [[b]]", "[[ T ]]"] {
            XCTAssertFalse(NoteDecoration.spans(source).contains { isCard($0.kind) },
                           "unexpected card in \(source)")
        }
    }
    func test_spans_cardInsideFence_staysRaw_andPartitionLossless() {
        let source = "```\n[[NotACard]]\n```\n\n[[Card]]\n"
        XCTAssertEqual(NoteDecoration.spans(source).filter { isCard($0.kind) },
                       [Span(range: NSRange(location: 22, length: 8),
                             kind: .subpageCard(target: "Card"))])
        assertPartitionLossless(source)
    }

    // MARK: - Marker visibility (Phase 1 / BAK-250 — Craft-style focus reveal)

    /// In scope for hiding: heading `#…# ` prefix, `**`/`*` emphasis delimiters,
    /// `` ` `` code delimiters, blockquote `> ` prefix. Deliberately OUT of scope
    /// (stay always dimmed-visible, unaffected by focus): bullet/ordered
    /// prefixes, fence delimiters, rule lines, wikilink brackets — see
    /// `NoteDecoration.hideableSpans`'s doc for why.

    func test_markerVisibility_noFocus_hidesEveryHideableMarker() {
        let source = "# H\n\npara **b** *i* `c`\n\n> quote\n"
        let ns = source as NSString
        let v = NoteDecoration.markerVisibility(source, focusedRange: nil)
        XCTAssertTrue(v.revealed.isEmpty)

        XCTAssertTrue(v.hidden.contains(ns.range(of: "# ")))
        XCTAssertTrue(v.hidden.contains(ns.range(of: "> ")))

        let boldFull = ns.range(of: "**b**")
        XCTAssertTrue(v.hidden.contains(NSRange(location: boldFull.location, length: 2)))
        XCTAssertTrue(v.hidden.contains(NSRange(location: boldFull.upperBound - 2, length: 2)))

        let italicFull = ns.range(of: "*i*")
        XCTAssertTrue(v.hidden.contains(NSRange(location: italicFull.location, length: 1)))
        XCTAssertTrue(v.hidden.contains(NSRange(location: italicFull.upperBound - 1, length: 1)))

        let codeFull = ns.range(of: "`c`")
        XCTAssertTrue(v.hidden.contains(NSRange(location: codeFull.location, length: 1)))
        XCTAssertTrue(v.hidden.contains(NSRange(location: codeFull.upperBound - 1, length: 1)))
    }

    func test_markerVisibility_cursorInHeading_revealsOnlyThatHeadingsPrefix() {
        let source = "# H\n\npara **b**\n"
        let ns = source as NSString
        let caret = ns.range(of: "H").location
        let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: caret, length: 0))

        XCTAssertTrue(v.revealed.contains(ns.range(of: "# ")))
        let boldFull = ns.range(of: "**b**")
        XCTAssertFalse(v.revealed.contains(NSRange(location: boldFull.location, length: 2)))
        XCTAssertTrue(v.hidden.contains(NSRange(location: boldFull.location, length: 2)))
    }

    func test_markerVisibility_cursorInParagraph_revealsBoldAndCodeMarkersThere_headingStaysHidden() {
        let source = "# H\n\npara **b** `c`\n"
        let ns = source as NSString
        let caret = ns.range(of: "para").location
        let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: caret, length: 0))

        let boldFull = ns.range(of: "**b**")
        XCTAssertTrue(v.revealed.contains(NSRange(location: boldFull.location, length: 2)))
        XCTAssertTrue(v.revealed.contains(NSRange(location: boldFull.upperBound - 2, length: 2)))
        let codeFull = ns.range(of: "`c`")
        XCTAssertTrue(v.revealed.contains(NSRange(location: codeFull.location, length: 1)))

        XCTAssertTrue(v.hidden.contains(ns.range(of: "# ")))
        XCTAssertFalse(v.revealed.contains(ns.range(of: "# ")))
    }

    func test_markerVisibility_cursorAtBlockBoundary_belongsToTheBlockThatStartsThere() {
        let source = "# H\n\npara **b**\n"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.count, 2)
        let boundary = blocks[0].range.upperBound
        XCTAssertEqual(boundary, blocks[1].range.location)

        let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: boundary, length: 0))
        let ns = source as NSString
        XCTAssertFalse(v.revealed.contains(ns.range(of: "# ")))
        let boldFull = ns.range(of: "**b**")
        XCTAssertTrue(v.revealed.contains(NSRange(location: boldFull.location, length: 2)))
    }

    func test_markerVisibility_caretAtDocumentEnd_fallsBackToLastBlock() {
        let source = "# H\n\npara **b**"
        let ns = source as NSString
        let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: ns.length, length: 0))
        let boldFull = ns.range(of: "**b**")
        XCTAssertTrue(v.revealed.contains(NSRange(location: boldFull.upperBound - 2, length: 2)))
        XCTAssertFalse(v.revealed.contains(ns.range(of: "# ")))
    }

    func test_markerVisibility_emptySelection_vs_rangeSelectionSpanningBlocks_allTouchedBlocksReveal() {
        let source = "# H\n\n> q\n\npara **b**\n"
        let ns = source as NSString
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.count, 3)

        // A zero-length caret only reveals the ONE block it sits in.
        let caretOnly = NoteDecoration.markerVisibility(
            source, focusedRange: NSRange(location: ns.range(of: "H").location, length: 0))
        XCTAssertTrue(caretOnly.revealed.contains(ns.range(of: "# ")))
        XCTAssertFalse(caretOnly.revealed.contains(ns.range(of: "> ")))

        // A range selection from inside the heading to inside the paragraph spans
        // all three blocks — every one of them reveals.
        let start = ns.range(of: "H").location
        let end = ns.range(of: "para").location + 1
        let selection = NSRange(location: start, length: end - start)
        let spanning = NoteDecoration.markerVisibility(source, focusedRange: selection)
        XCTAssertTrue(spanning.revealed.contains(ns.range(of: "# ")))
        XCTAssertTrue(spanning.revealed.contains(ns.range(of: "> ")))
        let boldFull = ns.range(of: "**b**")
        XCTAssertTrue(spanning.revealed.contains(NSRange(location: boldFull.location, length: 2)))
        XCTAssertTrue(spanning.hidden.isEmpty)
    }

    func test_markerVisibility_cursorInFrontmatter_frontmatterHasNoMarkers_restOfDocStaysHidden() {
        let source = "---\ntitle: X\n---\n\n# H\n"
        let ns = source as NSString
        let caret = ns.range(of: "title").location
        let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: caret, length: 0))
        XCTAssertTrue(v.hidden.contains(ns.range(of: "# ")))
        XCTAssertFalse(v.revealed.contains(ns.range(of: "# ")))
    }

    func test_markerVisibility_bulletOrderedFenceRuleWikilink_neverHiddenOrRevealed_anyFocus() {
        // Deliberately out of Phase 1's hiding scope (no substitute glyph exists
        // for these today) — never appear in either list, focused or not.
        let source = "- bullet\n\n1. one\n\n---\n\n```\ncode\n```\n\n[[Link]]\n"
        let ns = source as NSString

        let noFocus = NoteDecoration.markerVisibility(source, focusedRange: nil)
        XCTAssertTrue(noFocus.hidden.isEmpty)
        XCTAssertTrue(noFocus.revealed.isEmpty)

        for needle in ["bullet", "one", "---", "code", "Link"] {
            let loc = ns.range(of: needle).location
            let v = NoteDecoration.markerVisibility(source, focusedRange: NSRange(location: loc, length: 0))
            XCTAssertTrue(v.hidden.isEmpty, "expected nothing hidden with focus on \(needle)")
            XCTAssertTrue(v.revealed.isEmpty, "expected nothing revealed with focus on \(needle)")
        }
    }

    func test_revealedBlocks_nilFocus_isEmpty() {
        XCTAssertEqual(NoteDecoration.revealedBlocks("# H\npara", focusedRange: nil), [])
    }

    func test_revealedBlocks_returnsExactlyTheTouchedBlocks() {
        let source = "# H\n\npara\n"
        let blocks = NoteDecoration.blocks(source)
        let caret = (source as NSString).range(of: "para").location
        let revealed = NoteDecoration.revealedBlocks(source, focusedRange: NSRange(location: caret, length: 0))
        XCTAssertEqual(revealed, [blocks[1]])
    }

    func test_hideableMarkerRanges_headingBlock_isJustThePrefix() {
        let source = "# H\n"
        let block = NoteDecoration.blocks(source)[0]
        XCTAssertEqual(NoteDecoration.hideableMarkerRanges(source, in: block),
                       [NSRange(location: 0, length: 2)])
    }

    // MARK: - Empty heading/quote classification (regression: trailing-space trim)

    /// Bug repro: `classify()` used to check the heading/quote prefix against a
    /// BOTH-SIDES-trimmed string, which eats the one trailing space that marks
    /// "marker with no title/text yet" (e.g. right after the slash menu inserts
    /// "#### " and the user hasn't typed a title). That collapsed an empty
    /// heading to plain `.text`, so it never got heading styling OR (once
    /// focus moves away) Phase-1 marker hiding — it just sat there as literal
    /// "####" forever. Bullet/ordered already dodged this because they check
    /// against a leading-only trim; heading/quote must too.
    func test_blockKind_emptyHeadingWithTrailingSpaceNoTitle_stillClassifiesAsHeading() {
        for level in 1...6 {
            let source = String(repeating: "#", count: level) + " "
            let block = NoteDecoration.blocks(source)[0]
            XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .heading(level),
                           "level \(level) empty heading misclassified")
        }
    }

    func test_blockKind_emptyQuoteWithTrailingSpaceNoText_stillClassifiesAsQuote() {
        let source = "> "
        let block = NoteDecoration.blocks(source)[0]
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .quote)
    }

    /// The exact repro from the screenshot: a real H1 with a title, an empty H4
    /// just inserted (no title yet), then a checklist item.
    func test_blockKind_mixedDocumentWithEmptyHeading_classifiesAllThreeBlocksCorrectly() {
        let source = "# 12th July\n#### \n- [ ] "
        let blocks = NoteDecoration.blocks(source)
        XCTAssertEqual(blocks.map { NoteDecoration.blockKind(source, of: $0) },
                       [.heading(1), .heading(4), .todoList])
    }

    /// Once it correctly classifies as a heading, its marker becomes hideable —
    /// the whole point of fixing the classification (Phase 1 can only hide what
    /// it recognizes as a heading in the first place).
    func test_hideableMarkerRanges_emptyHeading_wholeLineIsTheMarker() {
        let source = "#### "
        let block = NoteDecoration.blocks(source)[0]
        XCTAssertEqual(NoteDecoration.hideableMarkerRanges(source, in: block),
                       [NSRange(location: 0, length: 5)])
    }

    /// No regression: real content after the marker still classifies and still
    /// only hides the prefix, not the title text.
    func test_blockKind_headingWithTrailingSpaceAfterRealTitle_stillClassifiesAsHeading() {
        let source = "## Title \n"   // trailing space AFTER real content
        let block = NoteDecoration.blocks(source)[0]
        XCTAssertEqual(NoteDecoration.blockKind(source, of: block), .heading(2))
    }

    // MARK: - Block glyphs (Craft-style rendered prefixes)

    private typealias BlockGlyph = NoteDecoration.BlockGlyph

    /// First block's `blockGlyph` result, plus a convenience slice of `source`
    /// via the returned `markerRange` — the shape every test below checks.
    private func glyph(_ source: String, blockIndex: Int = 0) -> (markerRange: NSRange, glyph: BlockGlyph)? {
        let blocks = NoteDecoration.blocks(source)
        return NoteDecoration.blockGlyph(source, of: blocks[blockIndex])
    }

    private func markerSlice(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    func test_blockGlyph_uncheckedTodo_withTrailingText() {
        let source = "- [ ] task"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .checkbox(checked: false))
        XCTAssertEqual(markerSlice(source, result!.markerRange), "- [ ] ")
    }

    func test_blockGlyph_checkedTodo_lowercaseX_withTrailingText() {
        let source = "- [x] done"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .checkbox(checked: true))
        XCTAssertEqual(markerSlice(source, result!.markerRange), "- [x] ")
    }

    func test_blockGlyph_checkedTodo_uppercaseX_withTrailingText() {
        let source = "- [X] done"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .checkbox(checked: true))
        XCTAssertEqual(markerSlice(source, result!.markerRange), "- [X] ")
    }

    func test_blockGlyph_bareUncheckedTodo_noTrailingSpaceOrText() {
        let source = "- [ ]"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .checkbox(checked: false))
        XCTAssertEqual(markerSlice(source, result!.markerRange), "- [ ]")
    }

    func test_blockGlyph_plainBullet_dash() {
        let source = "- item"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .bullet)
        XCTAssertEqual(markerSlice(source, result!.markerRange), "- ")
    }

    func test_blockGlyph_plainBullet_asterisk() {
        let source = "* item"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .bullet)
        XCTAssertEqual(markerSlice(source, result!.markerRange), "* ")
    }

    func test_blockGlyph_divider_dashes() {
        let source = "---"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .divider)
        XCTAssertEqual(markerSlice(source, result!.markerRange), "---")
    }

    func test_blockGlyph_divider_asterisks() {
        let source = "***"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .divider)
        XCTAssertEqual(markerSlice(source, result!.markerRange), "***")
    }

    func test_blockGlyph_quote() {
        let source = "> quoted"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .quote)
        XCTAssertEqual(markerSlice(source, result!.markerRange), "> ")
    }

    func test_blockGlyph_orderedList_isNil() {
        XCTAssertNil(glyph("1. item"))
    }

    func test_blockGlyph_heading_isNil() {
        XCTAssertNil(glyph("# Heading"))
    }

    func test_blockGlyph_plainParagraph_isNil() {
        XCTAssertNil(glyph("hello"))
    }

    func test_blockGlyph_indentedTodo_markerRangeIncludesLeadingSpaces() {
        let source = "  - [ ] x"
        let result = glyph(source)
        XCTAssertEqual(result?.glyph, .checkbox(checked: false))
        XCTAssertEqual(markerSlice(source, result!.markerRange), "  - [ ] ")
    }

    func test_blockGlyph_frontmatterBlock_isNil() {
        let source = "---\ntitle: X\n---\nbody"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertTrue(blocks[0].isFrontmatter)
        XCTAssertNil(NoteDecoration.blockGlyph(source, of: blocks[0]))
    }

    func test_blockGlyph_fencedCodeBlock_isNil() {
        let source = "```\n- [ ] not a checkbox\n```\n"
        let blocks = NoteDecoration.blocks(source)
        XCTAssertTrue(blocks[0].isFence)
        XCTAssertNil(NoteDecoration.blockGlyph(source, of: blocks[0]))
    }
}
