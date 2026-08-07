import Foundation

/// Pure decoration layer for the live Notes editor (Craft spec 2026-07-06, Phase 2a).
/// Maps markdown SOURCE → styled UTF-16 ranges + a total block partition. Read-only
/// by design: there is deliberately NO API that returns rewritten source — the
/// markdown-as-truth guarantee (spec hard constraint) is structural, not tested-in.
///
/// Operates on the RAW source string and never CRLF-normalizes — this layer must be
/// byte-faithful because its ranges index the exact string the text view holds
/// (text-view string == disk string). Contrast `MarkdownBlocks.parse`, which
/// normalizes because it only renders. All ranges are UTF-16 `NSRange`
/// (NSTextStorage coordinates), matching `WikilinkSyntax.Occurrence.range`.
public enum NoteDecoration {

    // MARK: - Blocks (total partition)

    public struct Block: Equatable {
        public let range: NSRange        // includes the block's trailing blank lines
        public let isFrontmatter: Bool   // leading --- YAML block (fences included)
        public let isFence: Bool         // ``` code block (fences included)

        public init(range: NSRange, isFrontmatter: Bool = false, isFence: Bool = false) {
            self.range = range
            self.isFrontmatter = isFrontmatter
            self.isFence = isFence
        }
    }

    /// Total partition of `source`: ranges are contiguous, in order, and cover every
    /// UTF-16 unit — substrings concatenated re-assemble the source EXACTLY.
    /// Grammar this editor doesn't understand (tables, setext, HTML) still lands in
    /// blocks (as paragraphs); nothing is dropped or normalized.
    ///
    /// Blocking mirrors `MarkdownBlocks.parse`'s line classification, but
    /// range-preserving: heading/rule/quote/list lines are one block per line,
    /// consecutive plain lines group into a paragraph, ``` fences swallow to the
    /// closing fence or EOF, and trailing blank lines attach to the preceding block
    /// (so blocks are the 2b drag units, separators included). Blank lines BEFORE
    /// the first block have no preceding block to join — they form one plain block
    /// of their own, keeping the partition total.
    public static func blocks(_ source: String) -> [Block] {
        let ns = source as NSString
        guard ns.length > 0 else { return [] }
        let all = lines(ns, in: NSRange(location: 0, length: ns.length))
        var blocks: [Block] = []
        var i = 0

        // Frontmatter: `Frontmatter.parse`'s detection rule applied to raw lines —
        // the FIRST line is exactly "---" and some later line closes it. Line
        // contents here already exclude the \n / \r\n terminator, so the raw
        // compare matches parse's normalize-then-compare without rewriting bytes.
        // Unterminated = not frontmatter; the opening "---" then reads as a rule.
        if all[0].content == "---",
           let close = all.dropFirst().firstIndex(where: { $0.content == "---" }) {
            var last = close
            while last + 1 < all.count, isBlank(all[last + 1]) { last += 1 }
            blocks.append(Block(range: NSRange(location: 0, length: all[last].range.upperBound),
                                isFrontmatter: true))
            i = last + 1
        }

        while i < all.count {
            let start = all[i].range.location
            var last = i
            var isFence = false

            switch classify(all[i].content) {
            case .blank:
                // Document-leading blank run (blanks after a block are absorbed
                // below and never reach the top of this loop).
                while last + 1 < all.count, isBlank(all[last + 1]) { last += 1 }
            case .fence:
                // Swallow to the closing fence or EOF — blank lines and would-be
                // markers inside stay inside, mirroring MarkdownBlocks' fence rule.
                isFence = true
                var j = i + 1
                while j < all.count, !isFenceLine(all[j]) { j += 1 }
                last = min(j, all.count - 1)
            case .text:
                // Consecutive plain lines group into one paragraph block.
                while last + 1 < all.count, case .text = classify(all[last + 1].content) { last += 1 }
            case .heading, .rule, .quote, .bullet, .ordered:
                break   // one block per line, exactly as MarkdownBlocks classifies
            }

            // Trailing blank lines attach to the block they follow.
            while last + 1 < all.count, isBlank(all[last + 1]) { last += 1 }

            blocks.append(Block(range: NSRange(location: start,
                                               length: all[last].range.upperBound - start),
                                isFence: isFence))
            i = last + 1
        }
        return blocks
    }

    // MARK: - BlockKind classification (Phase 0 / BAK-249)

    /// Classifies one `Block` as the shared `BlockKind` enum (see that type's doc
    /// for why `.frontmatter` isn't a case). Mirrors `spans(_:in:)`'s per-block
    /// entry point and the same fence/frontmatter-first ordering.
    ///
    /// `nil` means "frontmatter" — the only block that has no `BlockKind`. Every
    /// other block, including an all-blank block (a leading-blank-run block; see
    /// `blocks(_:)`'s doc) or a block past `source`'s bounds, classifies to a
    /// concrete case rather than `nil`, so callers can use `nil` as the
    /// frontmatter check without a second flag.
    public static func blockKind(_ source: String, of block: Block) -> BlockKind? {
        if block.isFrontmatter { return nil }
        if block.isFence { return .codeBlock }

        let ns = source as NSString
        guard block.range.upperBound <= ns.length else { return .paragraph }
        let blockLines = lines(ns, in: block.range)
        guard let first = blockLines.first else { return .paragraph }

        switch classify(first.content) {
        case .heading(let level):
            return .heading(level)
        case .rule:
            return .divider
        case .quote:
            return .quote
        case .ordered:
            return .numberedList
        case .bullet:
            return isTodoLine(first.content) ? .todoList : .bulletList
        case .blank, .fence:
            // A run of leading blank lines (its own block per `blocks(_:)`) or a
            // defensive fence-inside-a-normal-block case (can't happen — a fence
            // opens its own block) — both fall back to the paragraph default.
            return .paragraph
        case .text:
            let contentLines = blockLines.filter { !isBlank($0) }
            if contentLines.count == 1, let only = contentLines.first {
                if subpageCardTarget(only.content) != nil { return .subpage }
                if isImageLine(only.content) { return .image }
            }
            if isTableBlock(contentLines) { return .table }
            return .paragraph
        }
    }

    /// "- [ ] "/"- [x] "/"* [X] " (or the bare "[ ]"/"[x]"/"[X]" with nothing
    /// after) after the bullet's "- "/"* " prefix — the one shape that
    /// distinguishes a to-do item from a plain bullet. Case-sensitive only on the
    /// checked mark ("x" or "X"), matching common task-list convention.
    private static func isTodoLine(_ content: String) -> Bool {
        let afterIndent = content.drop { $0 == " " }
        let rest: Substring
        if afterIndent.hasPrefix("- ") || afterIndent.hasPrefix("* ") {
            rest = afterIndent.dropFirst(2)
        } else {
            return false
        }
        for marker in ["[ ]", "[x]", "[X]"] {
            if rest == marker || rest.hasPrefix(marker + " ") { return true }
        }
        return false
    }

    /// A full line that is exactly `![alt](url)` (whitespace-trimmed) — nothing
    /// before or after. Trailing text on the same line ("![a](b) hello") is
    /// deliberately NOT an image block; it stays an ordinary paragraph (Decision:
    /// spec's "image insert still writes syntax-only, no live preview" — this
    /// classifier only recognizes the line shape, it doesn't render a thumbnail).
    private static let imageLineRegex = try! NSRegularExpression(pattern: #"^!\[[^\]]*\]\([^)]*\)$"#)
    private static func isImageLine(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard ns.length > 0 else { return false }
        return imageLineRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// A table (new grammar this editor previously had no block type for — see
    /// spec Decision, `NoteDecoration`'s file doc): every non-blank line in the
    /// block contains "|", AND at least one line is a separator row (cells of
    /// only "-"/":" , e.g. `|---|---|` or `| :-- | --: |`). Requiring the
    /// separator row (not just pipes) is what keeps two arbitrary lines that
    /// happen to contain "|" from misclassifying as a table.
    private static func isTableBlock(_ contentLines: [Line]) -> Bool {
        guard contentLines.count >= 2,
              contentLines.allSatisfy({ $0.content.contains("|") })
        else { return false }
        return contentLines.contains { isTableSeparatorRow($0.content) }
    }

    private static func isTableSeparatorRow(_ content: String) -> Bool {
        var cells = content.trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A fully-piped row ("|---|---|") has empty leading/trailing cells from
        // the split — drop them; an un-piped edge ("---|---") keeps its cells.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    // MARK: - Block glyphs (Craft-style rendered prefixes)

    /// A block prefix the editor draws as a real glyph instead of raw markdown —
    /// the checkbox / bullet / divider / quote treatments. Purely a classification
    /// of the SOURCE; drawing and hit-testing live in the view.
    public enum BlockGlyph: Equatable {
        case checkbox(checked: Bool)   // "- [ ] " / "- [x] "
        case bullet                    // "- " / "* " (non-todo)
        case divider                   // "---" / "***"
        case quote                     // "> "
    }

    /// For a block whose first line carries a drawable prefix, the `markerRange`
    /// (the raw syntax the view suppresses — e.g. "- [ ] ", "- ", "---", "> ")
    /// and the `glyph` to draw in its place. `nil` for everything else (ordinary
    /// paragraphs, headings — whose `# ` is a hidden text marker, not a drawn
    /// glyph — numbered lists, which keep their visible "1. ", code, tables,
    /// images, subpages). Ranges are absolute UTF-16 offsets into `source`.
    public static func blockGlyph(_ source: String, of block: Block) -> (markerRange: NSRange, glyph: BlockGlyph)? {
        guard !block.isFrontmatter, !block.isFence else { return nil }
        let ns = source as NSString
        guard block.range.upperBound <= ns.length else { return nil }
        guard let first = lines(ns, in: block.range).first else { return nil }
        let content = first.content
        let base = first.contentRange.location

        switch classify(content) {
        case .rule:
            return (first.contentRange, .divider)
        case .quote:
            let prefix = leadingWhitespaceCount(content) + 2   // "> "
            return (NSRange(location: base, length: prefix), .quote)
        case .bullet:
            let indent = leadingSpaceCount(content)
            let afterBullet = content.dropFirst(indent).dropFirst(2)   // past "- "/"* "
            if let checkboxLen = todoMarkerLength(afterBullet) {
                // "- " + "[ ]"/"[x]"(+ optional trailing space)
                return (NSRange(location: base, length: indent + 2 + checkboxLen),
                        .checkbox(checked: isCheckedMarker(afterBullet)))
            }
            return (NSRange(location: base, length: indent + 2), .bullet)
        default:
            return nil
        }
    }

    /// Length of the "[ ]"/"[x]"/"[X]" checkbox marker (plus one trailing space if
    /// present) at the start of `afterBullet`, or `nil` if there's no checkbox.
    private static func todoMarkerLength(_ afterBullet: Substring) -> Int? {
        for marker in ["[ ]", "[x]", "[X]"] {
            if afterBullet == marker { return marker.count }
            if afterBullet.hasPrefix(marker + " ") { return marker.count + 1 }
        }
        return nil
    }

    private static func isCheckedMarker(_ afterBullet: Substring) -> Bool {
        afterBullet.hasPrefix("[x]") || afterBullet.hasPrefix("[X]")
    }

    // MARK: - Spans

    public struct Span: Equatable {
        public let range: NSRange
        public let kind: Kind

        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    public enum Kind: Equatable {
        case frontmatter                                  // whole YAML block incl. fences
        case heading(level: Int)                          // heading TEXT (hashes excluded)
        case marker                                       // syntax chars to de-emphasize
        case bold, italic, inlineCode                     // content between markers
        case strikethrough                                // `~~content~~` (Phase 4 / BAK-253)
        case highlight                                     // `==content==` (Phase 4 / BAK-253)
        case codeBlock                                    // fence interior
        case listMarker                                   // "- " / "1. " / "> " prefix
        case wikilink(target: String, alias: String?)     // the VISIBLE label span
        /// A plain paragraph line whose ENTIRE trimmed content is one bare
        /// wikilink (`[[Target]]` alone on the line) — 2b renders it as a subpage
        /// card. Additive: the line keeps its normal wikilink/marker spans (the
        /// characters stay, the link stays clickable); this span only grounds the
        /// card drawing behind them. Deliberately tight: aliases, anchors, embeds,
        /// or any surrounding text stay ordinary wikilinks.
        case subpageCard(target: String)
    }

    /// All spans for the whole source.
    public static func spans(_ source: String) -> [Span] {
        blocks(source).flatMap { spans(source, in: $0) }
    }

    /// Spans for one block only — the per-keystroke fast path (2a coordinator).
    public static func spans(_ source: String, in block: Block) -> [Span] {
        let ns = source as NSString
        guard block.range.upperBound <= ns.length else { return [] }

        // Frontmatter: one quiet span over the whole block (fences and any trailing
        // blank lines included) — nothing inside YAML is parsed (plan Decision 3).
        if block.isFrontmatter {
            return [Span(range: block.range, kind: .frontmatter)]
        }

        let blockLines = lines(ns, in: block.range)
        if block.isFence {
            return fenceSpans(blockLines, blockEnd: block.range.upperBound)
        }
        return blockLines.flatMap { lineSpans($0) }
    }

    // MARK: - Per-kind span builders

    /// Fence lines de-emphasize as `.marker` (language tag included); the interior —
    /// everything between them, newlines and all — is one `.codeBlock` span with NO
    /// inline/wikilink spans inside (matches `WikilinkIndex.extractLinks`' fence
    /// rule). An unterminated fence swallows to the block end.
    private static func fenceSpans(_ blockLines: [Line], blockEnd: Int) -> [Span] {
        guard let open = blockLines.first else { return [] }
        var spans = [Span(range: open.contentRange, kind: .marker)]

        let closeIndex = blockLines.indices.dropFirst().last(where: { isFenceLine(blockLines[$0]) })
        let interiorStart = open.range.upperBound
        let interiorEnd = closeIndex.map { blockLines[$0].range.location } ?? blockEnd
        if interiorEnd > interiorStart {
            spans.append(Span(range: NSRange(location: interiorStart,
                                             length: interiorEnd - interiorStart),
                              kind: .codeBlock))
        }
        if let closeIndex {
            spans.append(Span(range: blockLines[closeIndex].contentRange, kind: .marker))
        }
        return spans
    }

    /// Spans for one line of a normal (non-frontmatter, non-fence) block: a line
    /// prefix span per the line's class, then the shared inline scanner over the
    /// rest. A rule line is pure syntax — the whole line de-emphasizes as `.marker`.
    private static func lineSpans(_ line: Line) -> [Span] {
        let content = line.content
        let contentNS = content as NSString
        let base = line.contentRange.location

        switch classify(content) {
        case .blank:
            return []

        case .rule:
            return [Span(range: line.contentRange, kind: .marker)]

        case .heading(let level):
            // "#…# " prefix (leading indent included) is marker; the rest is the
            // heading text, which still gets inline spans (bold/links in headings).
            let prefix = leadingWhitespaceCount(content) + level + 1
            var spans = [Span(range: NSRange(location: base, length: prefix), kind: .marker)]
            let textLength = contentNS.length - prefix
            if textLength > 0 {
                spans.append(Span(range: NSRange(location: base + prefix, length: textLength),
                                  kind: .heading(level: level)))
                spans += inlineSpans(in: contentNS.substring(from: prefix), at: base + prefix)
            }
            return spans

        case .quote:
            return prefixedLineSpans(content, base: base,
                                     prefix: leadingWhitespaceCount(content) + 2)

        case .bullet:
            // Indent measured in raw leading SPACES, mirroring MarkdownBlocks.
            return prefixedLineSpans(content, base: base,
                                     prefix: leadingSpaceCount(content) + 2)

        case .ordered:
            let spaces = leadingSpaceCount(content)
            let digits = content.dropFirst(spaces).prefix { $0.isNumber }.count
            return prefixedLineSpans(content, base: base, prefix: spaces + digits + 2)

        case .text:
            var spans = inlineSpans(in: content, at: base)
            if let target = subpageCardTarget(content) {
                // Card span covers the line's content range (whitespace included)
                // so the drawn card grounds the whole line, not just the glyphs.
                spans.append(Span(range: line.contentRange, kind: .subpageCard(target: target)))
            }
            return spans

        case .fence:
            // A fence line inside a normal block can't happen (it opens its own
            // block); defensive raw.
            return []
        }
    }

    /// "- " / "1. " / "> " prefix (leading indent included) as `.listMarker`, then
    /// inline spans over the rest of the line.
    private static func prefixedLineSpans(_ content: String, base: Int, prefix: Int) -> [Span] {
        let contentNS = content as NSString
        var spans = [Span(range: NSRange(location: base, length: prefix), kind: .listMarker)]
        if contentNS.length > prefix {
            spans += inlineSpans(in: contentNS.substring(from: prefix), at: base + prefix)
        }
        return spans
    }

    // MARK: - Inline scanner (shared by heading/list/quote/paragraph lines)

    /// Deliberately tight inline grammar (anything else stays raw text): code spans
    /// first (opaque — no emphasis and no wikilinks inside, the fence rule one level
    /// down), then wikilinks (the ONE grammar: `WikilinkSyntax.regex`, group ranges
    /// read directly so markers/label split without re-deriving the pattern), then
    /// `**bold**`, then `*italic*`, then `~~strikethrough~~`, then `==highlight==`
    /// (Phase 4 / BAK-253 — added for the format-toolbar's "is already formatted"
    /// detection; same shape as bold/italic, just a different fixed-width
    /// delimiter). Single-line, non-nested; underscore emphasis is NOT parsed.
    /// Lookarounds on every symmetric-delimiter pattern keep unmatched/tripled
    /// runs ("**a", "***x***", "~~~y~~~") raw rather than guessed. A claimed-mask
    /// enforces first-wins.
    private static let codeSpanRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let boldRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*\*([^*]+)\*\*(?!\*)"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"(?<!~)~~([^~]+)~~(?!~)"#)
    private static let highlightRegex = try! NSRegularExpression(pattern: #"(?<!=)==([^=]+)==(?!=)"#)

    private static func inlineSpans(in text: String, at base: Int) -> [Span] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        var claimed = [Bool](repeating: false, count: ns.length)
        var spans: [Span] = []

        func isFree(_ r: NSRange) -> Bool {
            !(r.lowerBound..<r.upperBound).contains { claimed[$0] }
        }
        func claim(_ r: NSRange) {
            for k in r.lowerBound..<r.upperBound { claimed[k] = true }
        }
        func add(_ r: NSRange, _ kind: Kind) {
            guard r.length > 0 else { return }
            spans.append(Span(range: NSRange(location: base + r.location, length: r.length),
                              kind: kind))
        }

        for m in codeSpanRegex.matches(in: text, range: full) where isFree(m.range) {
            add(NSRange(location: m.range.location, length: 1), .marker)
            add(m.range(at: 1), .inlineCode)
            add(NSRange(location: m.range.upperBound - 1, length: 1), .marker)
            claim(m.range)
        }

        for m in WikilinkSyntax.regex.matches(in: text, range: full) where isFree(m.range) {
            let targetRange = m.range(at: 1)
            let target = ns.substring(with: targetRange).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }   // "[[ ]]" is not a link (WikilinkSyntax rule)
            let anchorRange = m.range(at: 2)
            let aliasRange = m.range(at: 4)

            // Leading "[[" (or "![[" for embeds).
            add(NSRange(location: m.range.location,
                        length: targetRange.location - m.range.location), .marker)
            if aliasRange.location != NSNotFound {
                // Aliased: target half, any #anchor, and the "|" all de-emphasize;
                // the alias is the visible label.
                let alias = ns.substring(with: aliasRange).trimmingCharacters(in: .whitespaces)
                add(NSRange(location: targetRange.location,
                            length: aliasRange.location - targetRange.location), .marker)
                add(aliasRange, .wikilink(target: target, alias: alias))
                add(NSRange(location: aliasRange.upperBound,
                            length: m.range.upperBound - aliasRange.upperBound), .marker)
            } else {
                add(targetRange, .wikilink(target: target, alias: nil))
                if anchorRange.location != NSNotFound { add(anchorRange, .marker) }
                let labelEnd = anchorRange.location != NSNotFound
                    ? anchorRange.upperBound : targetRange.upperBound
                add(NSRange(location: labelEnd, length: m.range.upperBound - labelEnd), .marker)
            }
            claim(m.range)
        }

        for m in boldRegex.matches(in: text, range: full) where isFree(m.range) {
            add(NSRange(location: m.range.location, length: 2), .marker)
            add(m.range(at: 1), .bold)
            add(NSRange(location: m.range.upperBound - 2, length: 2), .marker)
            claim(m.range)
        }

        for m in italicRegex.matches(in: text, range: full) where isFree(m.range) {
            add(NSRange(location: m.range.location, length: 1), .marker)
            add(m.range(at: 1), .italic)
            add(NSRange(location: m.range.upperBound - 1, length: 1), .marker)
            claim(m.range)
        }

        for m in strikethroughRegex.matches(in: text, range: full) where isFree(m.range) {
            add(NSRange(location: m.range.location, length: 2), .marker)
            add(m.range(at: 1), .strikethrough)
            add(NSRange(location: m.range.upperBound - 2, length: 2), .marker)
            claim(m.range)
        }

        for m in highlightRegex.matches(in: text, range: full) where isFree(m.range) {
            add(NSRange(location: m.range.location, length: 2), .marker)
            add(m.range(at: 1), .highlight)
            add(NSRange(location: m.range.upperBound - 2, length: 2), .marker)
            claim(m.range)
        }

        return spans
    }

    /// The subpage-card shape (2b, deliberately tight): the trimmed line is
    /// exactly `[[Target]]` — no alias, no `#anchor`, no `![[embed]]`, no
    /// surrounding text, and the target carries no stray brackets/pipes and no
    /// edge whitespace (`[[ T ]]`'s raw inner " T " differs from the trimmed
    /// target WikilinkSyntax/resolvers use, so it stays an ordinary link rather
    /// than a card with a mismatched title). Anything looser renders as a normal
    /// wikilink.
    private static func subpageCardTarget(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") else { return nil }
        let target = String(trimmed.dropFirst(2).dropLast(2))
        guard !target.isEmpty,
              !target.contains("["), !target.contains("]"),
              !target.contains("|"), !target.contains("#"),
              target == target.trimmingCharacters(in: .whitespaces)
        else { return nil }
        return target
    }

    // MARK: - Marker visibility (Phase 1 / BAK-250 — Craft-style focus reveal)

    /// One `markerVisibility(_:focusedRange:)` result: the document's hideable
    /// marker ranges split by whether their containing block is currently
    /// focused. Pure decision only — this type never hides anything itself;
    /// `MarkdownTextView` is the presentation layer that turns `hidden` ranges
    /// into a TextKit "not shown" glyph flag (see that file's doc for why that
    /// mechanism keeps the underlying text and its attributes untouched).
    public struct MarkerVisibility: Equatable {
        public let hidden: [NSRange]
        public let revealed: [NSRange]

        public init(hidden: [NSRange], revealed: [NSRange]) {
            self.hidden = hidden
            self.revealed = revealed
        }
    }

    /// Given `source` and the editor's current focus, which of the document's
    /// hideable marker ranges should render hidden vs revealed. `focusedRange`
    /// `nil` means the editor has NO focus at all (e.g. the window resigned key)
    /// — every marker in the document hides. Otherwise `focusedRange` is the
    /// text view's selection: a zero-length range is a caret, a non-zero range a
    /// selection.
    ///
    /// Reveal is decided at BLOCK granularity — the same unit
    /// `MarkdownTextView`'s existing caret-scoped decoration pass already uses —
    /// not per character: every block `focusedRange` touches reveals ALL its
    /// hideable markers; every other block's hideable markers hide. See
    /// `focusedBlockIndices` for the exact boundary/selection rules, and
    /// `hideableSpans` for exactly which syntax is in scope.
    public static func markerVisibility(_ source: String, focusedRange: NSRange?) -> MarkerVisibility {
        let all = blocks(source)
        guard !all.isEmpty else { return MarkerVisibility(hidden: [], revealed: []) }
        let focused: Set<Int> = focusedRange.map { focusedBlockIndices(all, focusedRange: $0) } ?? []

        var hidden: [NSRange] = []
        var revealed: [NSRange] = []
        for (index, block) in all.enumerated() {
            let ranges = hideableSpans(source, in: block).map(\.range)
            if focused.contains(index) {
                revealed += ranges
            } else {
                hidden += ranges
            }
        }
        return MarkerVisibility(hidden: hidden, revealed: revealed)
    }

    /// The blocks currently revealed for `focusedRange` (empty when `nil`) — the
    /// block-level view of `markerVisibility`'s decision. Exposed separately so a
    /// caller holding the previous call's result can diff the two `[Block]`
    /// arrays and re-touch only the blocks whose membership changed, instead of
    /// re-deriving every marker range on every selection move
    /// (`MarkdownTextView`'s incremental selection-change path).
    public static func revealedBlocks(_ source: String, focusedRange: NSRange?) -> [Block] {
        guard let focusedRange else { return [] }
        let all = blocks(source)
        return focusedBlockIndices(all, focusedRange: focusedRange).sorted().map { all[$0] }
    }

    /// The hideable marker ranges within exactly one block — the per-block slice
    /// `MarkdownTextView`'s incremental path re-touches when only that one
    /// block's reveal state changed.
    public static func hideableMarkerRanges(_ source: String, in block: Block) -> [NSRange] {
        hideableSpans(source, in: block).map(\.range)
    }

    /// Block indices `focusedRange` touches. A zero-length range (a caret)
    /// belongs to the block whose HALF-OPEN range contains it — the same
    /// `NSLocationInRange` convention `MarkdownTextView`'s `caretBlock` already
    /// uses — so a caret sitting exactly on a block boundary belongs to the
    /// block that STARTS there, never both. A caret past every block's
    /// half-open range (only possible at the very end of the document) falls
    /// back to the last block, mirroring that same call site's `?? blocks.last`.
    /// A non-zero selection touches every block it overlaps
    /// (`NSIntersectionRange(...).length > 0`) — how a selection spanning
    /// several blocks reveals all of them.
    private static func focusedBlockIndices(_ blocks: [Block], focusedRange: NSRange) -> Set<Int> {
        guard !blocks.isEmpty else { return [] }
        if focusedRange.length == 0 {
            if let index = blocks.firstIndex(where: { NSLocationInRange(focusedRange.location, $0.range) }) {
                return [index]
            }
            return [blocks.count - 1]
        }
        var result = Set<Int>()
        for (index, block) in blocks.enumerated()
            where NSIntersectionRange(block.range, focusedRange).length > 0 {
            result.insert(index)
        }
        return result
    }

    /// Which of one block's EXISTING `.marker`/`.listMarker` spans are in Phase
    /// 1's hiding scope: a heading's `#…# ` prefix, a blockquote's `> ` prefix,
    /// and `**`/`*`/`` ` ``/`~~`/`==` emphasis-or-code-or-strikethrough-or-
    /// highlight delimiters (checked in ANY block kind — inline formatting
    /// reads the same inside a paragraph, heading, quote, or list item).
    /// `~~`/`==` (Phase 4 / BAK-253) integrate here for free: they're just two
    /// more cases in `isDelimitedContent` below, because `inlineSpans` already
    /// places their `.marker` spans directly adjacent to their content spans,
    /// exactly like bold/italic/inlineCode. Deliberately NOT in scope, so they stay exactly as
    /// dimmed-and-always-visible as they are today, focus or not:
    ///   - bullet ("- "/"* ") and ordered ("1. ") prefixes — hiding them would
    ///     leave a list item with no visual marker at all; no bullet/number
    ///     glyph exists to take their place yet.
    ///   - fence delimiters and rule lines — hiding the only visible cue for a
    ///     code block's or divider's boundary would leave nothing on screen
    ///     where the line used to be.
    ///   - wikilink brackets — links are their own considered surface (pills /
    ///     subpage cards), not this phase's scope.
    /// Checkbox bracket syntax ("- [ ]"/"- [x]") isn't handled here either: it
    /// has no distinct span today (plain paragraph text inside a bullet line,
    /// per `spans(_:in:)`/`isTodoLine`), so there is nothing for this function
    /// to classify — nothing changes for it in either direction.
    private static func hideableSpans(_ source: String, in block: Block) -> [Span] {
        let all = spans(source, in: block)
        guard !all.isEmpty else { return [] }
        let kind = blockKind(source, of: block)

        var result: [Span] = []
        if case .heading = kind, let prefix = all.first(where: { $0.kind == .marker }) {
            result.append(prefix)
        }
        if kind == .quote, let prefix = all.first(where: { $0.kind == .listMarker }) {
            result.append(prefix)
        }

        // Emphasis/code delimiters: a `.marker` span immediately touching a
        // `.bold`/`.italic`/`.inlineCode` content span. By construction (the
        // shared regex match in `inlineSpans`) a delimiter is always directly
        // adjacent to its own content span, in every block kind, so this check
        // doesn't need `kind` at all.
        func isDelimitedContent(_ k: Kind) -> Bool {
            switch k {
            case .bold, .italic, .inlineCode, .strikethrough, .highlight: return true
            default: return false
            }
        }
        let contentRanges = all.filter { isDelimitedContent($0.kind) }.map(\.range)
        for span in all where span.kind == .marker {
            let touchesContent = contentRanges.contains {
                $0.location == span.range.upperBound || $0.upperBound == span.range.location
            }
            if touchesContent { result.append(span) }
        }
        return result
    }

    // MARK: - Line scanning + classification

    /// One raw line: `range` includes the terminator (\n, \r, or \r\n — kept with
    /// the owning line so the partition never splits a CRLF pair), `contentRange`
    /// and `content` exclude it.
    private struct Line {
        let range: NSRange
        let contentRange: NSRange
        let content: String
    }

    /// Line ranges via `getLineStart` (never `components(separatedBy:)`, which
    /// loses \r\n fidelity). A trailing newline belongs to the last line's range,
    /// so no phantom empty line is produced after it.
    private static func lines(_ ns: NSString, in range: NSRange) -> [Line] {
        var result: [Line] = []
        var location = range.location
        let limit = range.upperBound
        while location < limit {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let contentRange = NSRange(location: start, length: contentsEnd - start)
            result.append(Line(range: NSRange(location: start, length: end - start),
                               contentRange: contentRange,
                               content: ns.substring(with: contentRange)))
            location = end
        }
        return result
    }

    /// Widened from `private` to `internal`: `BlockTransform`'s "turn into"
    /// escape discipline (BAK-252 review fix) needs to know whether a
    /// candidate PARAGRAPH line would reclassify as some other line kind, and
    /// must ask THIS classifier rather than re-deriving the marker rules
    /// itself — the drift this shared classification layer exists to prevent.
    enum LineKind {
        case blank, fence, rule, quote, bullet, ordered, text
        case heading(Int)
    }

    /// Same predicates as `MarkdownBlocks.blockLine`, same order (rule before
    /// heading; fence before everything non-blank). See `LineKind`'s doc for
    /// why this is `internal` rather than `private`.
    static func classify(_ content: String) -> LineKind {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("```") { return .fence }
        if trimmed == "---" || trimmed == "***" { return .rule }
        // Leading-whitespace-only trim (tabs included, matching `leadingWhitespaceCount`
        // and `lineSpans`' heading/quote prefix-length math) — deliberately NOT
        // `trimmed`, which also strips TRAILING whitespace and would eat the one
        // space an EMPTY heading/quote ("#### " or "> " with no title/text yet —
        // e.g. right after the slash menu inserts the template and before the user
        // types) needs to classify correctly. Bullet/ordered below already dodge
        // this bug because they check their own from-scratch `afterIndent`.
        let afterLeadingWhitespace = content.drop { $0 == " " || $0 == "\t" }
        if let level = headingLevel(afterLeadingWhitespace) { return .heading(level) }
        if afterLeadingWhitespace.hasPrefix("> ") { return .quote }
        let afterIndent = content.drop { $0 == " " }
        if afterIndent.hasPrefix("- ") || afterIndent.hasPrefix("* ") { return .bullet }
        if isOrdered(afterIndent) { return .ordered }
        return .text
    }

    /// `#{1,6} ` → the level; seven hashes or no trailing space is not a heading.
    private static func headingLevel(_ afterLeadingWhitespace: Substring) -> Int? {
        let hashes = afterLeadingWhitespace.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6, afterLeadingWhitespace.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    /// `\d+. ` — only the dot form, matching MarkdownBlocks' light scope.
    private static func isOrdered(_ afterIndent: Substring) -> Bool {
        let digits = afterIndent.prefix { $0.isNumber }.count
        return digits >= 1 && afterIndent.dropFirst(digits).hasPrefix(". ")
    }

    private static func isBlank(_ line: Line) -> Bool {
        line.content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFenceLine(_ line: Line) -> Bool {
        line.content.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// All whitespace characters are single UTF-16 units, so a Character count is
    /// a valid UTF-16 offset here.
    private static func leadingWhitespaceCount(_ content: String) -> Int {
        content.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func leadingSpaceCount(_ content: String) -> Int {
        content.prefix { $0 == " " }.count
    }
}
