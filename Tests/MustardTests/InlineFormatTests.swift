import XCTest
@testable import MustardKit

/// TDD for the floating format-toolbar's pure logic (Craft spec 2026-07-12,
/// Phase 4 / BAK-253 — last phase of epic BAK-248). `InlineFormat.toggle`
/// wraps an unformatted selection or unwraps an already-formatted one; every
/// "is this already formatted" check reuses `NoteDecoration`'s span grammar
/// (bold/italic/strikethrough/inlineCode/highlight) rather than re-deriving
/// it — see `InlineFormat.swift`'s doc for why `.link` is the one exception
/// (no existing grammar to reuse: `NoteDecoration` never parses
/// `[text](url)`, only `[[wikilinks]]`).
final class InlineFormatTests: XCTestCase {

    // MARK: - Wrap (toggle ON — unformatted selection)

    func test_toggle_bold_wrapsSelection_shiftsSelectionPastLeadingDelimiter() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)   // "world"
        let result = InlineFormat.toggle(source, selection: selection, format: .bold)
        XCTAssertEqual(result?.source, "hello **world**")
        XCTAssertEqual(result?.selection, NSRange(location: 8, length: 5))
    }

    func test_toggle_italic_wrapsSelection() {
        let source = "hello world"
        let selection = NSRange(location: 0, length: 5)   // "hello"
        let result = InlineFormat.toggle(source, selection: selection, format: .italic)
        XCTAssertEqual(result?.source, "*hello* world")
        XCTAssertEqual(result?.selection, NSRange(location: 1, length: 5))
    }

    func test_toggle_strikethrough_wrapsSelection() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .strikethrough)
        XCTAssertEqual(result?.source, "hello ~~world~~")
        XCTAssertEqual(result?.selection, NSRange(location: 8, length: 5))
    }

    func test_toggle_inlineCode_wrapsSelection() {
        let source = "call foo now"
        let selection = NSRange(location: 5, length: 3)   // "foo"
        let result = InlineFormat.toggle(source, selection: selection, format: .inlineCode)
        XCTAssertEqual(result?.source, "call `foo` now")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 3))
    }

    func test_toggle_highlight_wrapsSelection() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .highlight)
        XCTAssertEqual(result?.source, "hello ==world==")
        XCTAssertEqual(result?.selection, NSRange(location: 8, length: 5))
    }

    // MARK: - Unwrap (toggle OFF — content-only selection, case a)

    func test_toggle_bold_contentOnlySelection_unwraps() {
        let source = "hello **world**"
        let selection = NSRange(location: 8, length: 5)   // "world" (no markers)
        let result = InlineFormat.toggle(source, selection: selection, format: .bold)
        XCTAssertEqual(result?.source, "hello world")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 5))
    }

    func test_toggle_italic_contentOnlySelection_unwraps() {
        let source = "*hello* world"
        let selection = NSRange(location: 1, length: 5)   // "hello"
        let result = InlineFormat.toggle(source, selection: selection, format: .italic)
        XCTAssertEqual(result?.source, "hello world")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 5))
    }

    func test_toggle_strikethrough_contentOnlySelection_unwraps() {
        let source = "hello ~~world~~"
        let selection = NSRange(location: 8, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .strikethrough)
        XCTAssertEqual(result?.source, "hello world")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 5))
    }

    func test_toggle_highlight_contentOnlySelection_unwraps() {
        let source = "hello ==world=="
        let selection = NSRange(location: 8, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .highlight)
        XCTAssertEqual(result?.source, "hello world")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 5))
    }

    func test_toggle_inlineCode_contentOnlySelection_unwraps() {
        let source = "call `foo` now"
        let selection = NSRange(location: 6, length: 3)   // "foo"
        let result = InlineFormat.toggle(source, selection: selection, format: .inlineCode)
        XCTAssertEqual(result?.source, "call foo now")
        XCTAssertEqual(result?.selection, NSRange(location: 5, length: 3))
    }

    // MARK: - Unwrap (toggle OFF — selection includes the delimiters, case b)

    func test_toggle_bold_outerSelection_includingMarkers_unwraps() {
        let source = "hello **world**"
        let selection = NSRange(location: 6, length: 9)   // "**world**"
        let result = InlineFormat.toggle(source, selection: selection, format: .bold)
        XCTAssertEqual(result?.source, "hello world")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 5))
    }

    func test_toggle_strikethrough_outerSelection_unwraps() {
        let source = "a ~~b~~ c"
        let selection = NSRange(location: 2, length: 5)   // "~~b~~"
        let result = InlineFormat.toggle(source, selection: selection, format: .strikethrough)
        XCTAssertEqual(result?.source, "a b c")
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 1))
    }

    // MARK: - Involution: toggle twice returns byte-identical original

    func test_involution_bold_wrapThenUnwrap_restoresOriginalSourceAndSelection() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)
        let wrapped = InlineFormat.toggle(source, selection: selection, format: .bold)!
        let restored = InlineFormat.toggle(wrapped.source, selection: wrapped.selection, format: .bold)!
        XCTAssertEqual(restored.source, source)
        XCTAssertEqual(restored.selection, selection)
    }

    func test_involution_everySymmetricFormat_wrapThenUnwrap_isIdentity() {
        let source = "line of text here"
        let selection = NSRange(location: 8, length: 4)   // "text"
        for format: InlineFormat.Kind in [.bold, .italic, .strikethrough, .inlineCode, .highlight] {
            let wrapped = InlineFormat.toggle(source, selection: selection, format: format)!
            let restored = InlineFormat.toggle(wrapped.source, selection: wrapped.selection, format: format)!
            XCTAssertEqual(restored.source, source, "format \(format) failed to round-trip")
            XCTAssertEqual(restored.selection, selection, "format \(format) selection drifted")
        }
    }

    // MARK: - Round-trip: toggled output parses back with the expected span

    func test_roundTrip_wrappedOutput_parsesBackAsExpectedSpanKind() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .bold)!
        let spans = NoteDecoration.spans(result.source)
        XCTAssertTrue(spans.contains(NoteDecoration.Span(range: result.selection, kind: .bold)))
    }

    func test_roundTrip_highlightWrappedOutput_parsesBackAsHighlight() {
        let source = "hello world"
        let selection = NSRange(location: 6, length: 5)
        let result = InlineFormat.toggle(source, selection: selection, format: .highlight)!
        let spans = NoteDecoration.spans(result.source)
        XCTAssertTrue(spans.contains(NoteDecoration.Span(range: result.selection, kind: .highlight)))
    }

    // MARK: - Empty selection: no-op (documented policy)

    func test_toggle_emptySelection_isNoOp() {
        let source = "hello world"
        XCTAssertNil(InlineFormat.toggle(source, selection: NSRange(location: 3, length: 0), format: .bold))
    }

    // MARK: - Selection spanning a block boundary: no-op (documented policy)

    func test_toggle_selectionSpanningTwoBlocks_isNoOp() {
        let source = "# Heading\n\npara text"
        // Selection from inside the heading to inside the paragraph.
        let ns = source as NSString
        let start = ns.range(of: "Heading").location
        let end = ns.range(of: "para").location + 2
        let selection = NSRange(location: start, length: end - start)
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .bold))
    }

    func test_toggle_selectionInFrontmatter_isNoOp() {
        let source = "---\ntitle: X\n---\nbody text"
        let ns = source as NSString
        let selection = ns.range(of: "title")
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .bold))
    }

    // MARK: - Partial overlap: no-op (documented policy)

    func test_toggle_partialOverlapWithSameKindSpan_isNoOp() {
        // Selection covers "lo **wo" — half outside, half inside the bold span.
        let source = "hello **world**"
        let ns = source as NSString
        let boldStart = ns.range(of: "**world**").location
        let selection = NSRange(location: boldStart - 2, length: 5)   // "lo **w" roughly
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .bold))
    }

    func test_toggle_partialOverlapIncludingOnlyOneDelimiter_isNoOp() {
        // Selection = "*world*" minus the trailing marker: "*world" (missing close).
        let source = "*world* end"
        let selection = NSRange(location: 0, length: 6)   // "*world" (excludes closing *)
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .italic))
    }

    // MARK: - Different-kind nesting: only succeeds when the wrap actually
    // round-trips (task.md criterion 5). `NoteDecoration`'s inline scanner is a
    // first-wins claimed-mask over a FIXED order (code, wikilink, bold, italic,
    // strikethrough, highlight) — an outer wrap earlier in that order still
    // claims its full range and parses fine even with a later-kind span nested
    // inside; an outer wrap LATER in that order finds its own delimiters
    // already claimed by the inner (earlier) kind and never parses as the
    // outer kind at all. Rather than silently emitting markdown that LOOKS
    // like it should format but won't decorate, `toggle` verifies the wrap
    // parses back as the target kind and rejects (`nil`) it if not.

    func test_toggle_wrapEarlierKindAroundLaterKindSpan_succeeds() {
        // bold (earlier in scan order) wrapping around an existing highlight
        // span (later) — bold's regex still wins the claimed-mask race.
        let source = "text ==marked== text"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let result = InlineFormat.toggle(source, selection: selection, format: .bold)
        XCTAssertEqual(result?.source, "**text ==marked== text**")
        let spans = NoteDecoration.spans(result!.source)
        XCTAssertTrue(spans.contains { $0.kind == .bold && $0.range == result!.selection })
    }

    func test_toggle_wrapLaterKindAroundEarlierKindSpan_rejectedAsNoOp() {
        // highlight (later in scan order) wrapping around an existing bold
        // span (earlier) — bold claims those characters first, so the
        // highlight delimiters never parse as a highlight span. No-op.
        let source = "text **bold** text"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .highlight))
    }

    func test_toggle_wrapSelectionCrossingLineBreak_rejectedAsNoOp() {
        // Same paragraph BLOCK (no blank-line boundary), but the delimiters
        // would land on two different LINES — `NoteDecoration`'s inline
        // scanner runs strictly per-line, so this could never parse back as
        // one span. Rejected rather than emitting dead-looking markup.
        let source = "line one\nline two"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertNil(InlineFormat.toggle(source, selection: selection, format: .bold))
    }

    // MARK: - Link

    func test_toggle_link_wrapsSelection_selectsUrlPlaceholder() {
        let source = "see docs here"
        let ns = source as NSString
        let selection = ns.range(of: "docs")
        let result = InlineFormat.toggle(source, selection: selection, format: .link)!
        XCTAssertEqual(result.source, "see [docs](url) here")
        let resultNS = result.source as NSString
        XCTAssertEqual(resultNS.substring(with: result.selection), InlineFormat.linkURLPlaceholder)
    }

    func test_toggle_link_contentOnlySelection_unwraps() {
        let source = "see [docs](https://x) here"
        let ns = source as NSString
        let selection = ns.range(of: "docs")
        let result = InlineFormat.toggle(source, selection: selection, format: .link)!
        XCTAssertEqual(result.source, "see docs here")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 4))
    }

    func test_toggle_link_outerSelection_includingBracketsAndUrl_unwraps() {
        let source = "see [docs](https://x) here"
        let ns = source as NSString
        let selection = ns.range(of: "[docs](https://x)")
        let result = InlineFormat.toggle(source, selection: selection, format: .link)!
        XCTAssertEqual(result.source, "see docs here")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 4))
    }

    func test_involution_link_wrapThenUnwrapOverText_restoresOriginal() {
        let source = "see docs here"
        let ns = source as NSString
        let selection = ns.range(of: "docs")
        let wrapped = InlineFormat.toggle(source, selection: selection, format: .link)!
        // Link's post-wrap selection is the URL placeholder (documented
        // exception to "same text stays selected") — re-select the LINK TEXT
        // in the wrapped source to exercise the round trip.
        let wrappedNS = wrapped.source as NSString
        let textSelection = wrappedNS.range(of: "docs")
        let restored = InlineFormat.toggle(wrapped.source, selection: textSelection, format: .link)!
        XCTAssertEqual(restored.source, source)
        XCTAssertEqual(restored.selection, selection)
    }

    // MARK: - isSingleBlockSelection (visibility-gating helper the toolbar uses)

    func test_isSingleBlockSelection_trueWithinOneBlock() {
        let source = "para one\n\npara two"
        let ns = source as NSString
        XCTAssertTrue(InlineFormat.isSingleBlockSelection(source, selection: ns.range(of: "one")))
    }

    func test_isSingleBlockSelection_falseAcrossBlocks() {
        let source = "# H\n\npara"
        let ns = source as NSString
        let start = ns.range(of: "H").location
        let end = ns.range(of: "para").location + 1
        XCTAssertFalse(InlineFormat.isSingleBlockSelection(source, selection: NSRange(location: start, length: end - start)))
    }

    func test_isSingleBlockSelection_falseForEmptySelection() {
        XCTAssertFalse(InlineFormat.isSingleBlockSelection("hello", selection: NSRange(location: 2, length: 0)))
    }
}
