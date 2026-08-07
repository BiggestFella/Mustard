import Foundation

/// Pure inline-formatting toggle for the floating format toolbar (Craft spec
/// 2026-07-12, Phase 4 / BAK-253 — last phase of epic BAK-248). One entry
/// point, `toggle(_:selection:format:)`: given the note SOURCE and the
/// caller's current SELECTION, decides whether the selection is already
/// wrapped in `format`'s markdown delimiters — reusing `NoteDecoration`'s
/// span grammar for that detection, this file never re-derives what "bold"
/// or "italic" LOOKS like — and either unwraps it or wraps it, returning the
/// new source and the new selection (same TEXT selected, delimiters never
/// included). `nil` means "no-op": every no-op case below is a deliberate
/// policy decision (documented inline), not a missing case.
///
/// `.link` is the one format `NoteDecoration` has no grammar for at all
/// (`[text](url)` isn't in its `Kind` enum — only `[[wikilinks]]` are parsed)
/// — so `.link`'s own already-linked detection lives entirely in this file;
/// there is no existing span grammar to duplicate for it.
public enum InlineFormat {

    public enum Kind: Equatable, Hashable, CaseIterable {
        case bold, italic, strikethrough, inlineCode, highlight, link
    }

    public struct Result: Equatable {
        public let source: String
        public let selection: NSRange

        public init(source: String, selection: NSRange) {
            self.source = source
            self.selection = selection
        }
    }

    /// The literal placeholder text a fresh link's URL slot gets — visible
    /// (not empty) so there's something to select, matching the objective's
    /// "caret landing in the url slot". This is the ONE format whose
    /// post-wrap selection is NOT the original text (see `toggle`'s policy
    /// notes) — the user's very next action is typing the URL, so the
    /// toolbar selects the placeholder instead of the link text.
    public static let linkURLPlaceholder = "url"

    // MARK: - Policy (edge cases, task.md criterion 2)
    //
    // - Empty selection (`selection.length == 0`): no-op. The toolbar itself
    //   only mounts for a non-empty selection (spec: "appears only for
    //   selection length > 0"), so this is unreachable from the UI today —
    //   but the pure API still needs a defined answer, and "format nothing"
    //   has no sensible wrap/unwrap.
    // - Selection spanning more than one `NoteDecoration.Block`, or landing
    //   in/over the frontmatter block: no-op. Conservative per "silent
    //   partial application is not acceptable" — formatting across a block
    //   boundary (half a heading, half a paragraph) has no single
    //   well-defined delimiter placement, and frontmatter is YAML, not
    //   content `NoteDecoration` styles at all.
    // - Selection that PARTIALLY overlaps an existing span/delimiter of the
    //   SAME target format (not a clean content-only or content+delimiters
    //   match): no-op. Wrapping would nest same-kind delimiters
    //   ("**abc **d**"), which doesn't round-trip.
    // - A wrap whose result would NOT parse back as the target kind (e.g. a
    //   selection crossing a line break inside one multi-line paragraph
    //   block — `NoteDecoration`'s inline scanner runs strictly per-line; or
    //   wrapping a kind that's LATER in the fixed inline-scan order — code,
    //   wikilink, bold, italic, strikethrough, highlight — around a span of
    //   an EARLIER kind, which claims the characters first): no-op, verified
    //   by re-parsing the candidate result with `NoteDecoration.spans`
    //   before returning it (task.md criterion 5's round-trip guarantee,
    //   enforced rather than just tested).

    public static func toggle(_ source: String, selection: NSRange, format: Kind) -> Result? {
        guard selection.length > 0 else { return nil }
        let ns = source as NSString
        guard selection.upperBound <= ns.length else { return nil }

        let blocks = NoteDecoration.blocks(source)
        guard let block = containingBlock(blocks, selection: selection), !block.isFrontmatter else { return nil }

        if format == .link {
            return toggleLink(source, selection: selection)
        }
        return toggleDelimited(source, selection: selection, block: block, format: format)
    }

    /// Whether `selection` sits fully inside exactly one (non-frontmatter)
    /// block — the toolbar's own visibility gate (`MarkdownTextView`'s
    /// coordinator calls this to decide whether to show/hide, so the "single
    /// block" rule lives in exactly one place rather than being re-derived by
    /// the view layer).
    public static func isSingleBlockSelection(_ source: String, selection: NSRange) -> Bool {
        guard selection.length > 0 else { return false }
        let blocks = NoteDecoration.blocks(source)
        guard let block = containingBlock(blocks, selection: selection) else { return false }
        return !block.isFrontmatter
    }

    private static func containingBlock(_ blocks: [NoteDecoration.Block], selection: NSRange) -> NoteDecoration.Block? {
        blocks.first {
            $0.range.location <= selection.location && selection.upperBound <= $0.range.upperBound
        }
    }

    // MARK: - Symmetric-delimiter formats (bold/italic/strikethrough/inlineCode/highlight)

    private static func delimiter(_ format: Kind) -> String {
        switch format {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .inlineCode: return "`"
        case .highlight: return "=="
        case .link: return ""   // unreachable — link has its own path
        }
    }

    private static func decorationKind(_ format: Kind) -> NoteDecoration.Kind? {
        switch format {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .inlineCode: return .inlineCode
        case .highlight: return .highlight
        case .link: return nil
        }
    }

    private static func toggleDelimited(_ source: String, selection: NSRange,
                                        block: NoteDecoration.Block, format: Kind) -> Result? {
        guard let kind = decorationKind(format) else { return nil }
        let delim = delimiter(format)
        let delimLen = (delim as NSString).length
        let ns = source as NSString

        let sameKindSpans = NoteDecoration.spans(source, in: block).filter { $0.kind == kind }

        // Case (a): selection is EXACTLY a content span's range — the plain
        // text between the delimiters, no markers selected. Unwrap.
        if sameKindSpans.contains(where: { $0.range == selection }) {
            return unwrap(source, contentRange: selection, delimLen: delimLen)
        }

        // Case (b): selection is EXACTLY delimiter+content+delimiter — the
        // user dragged over the markers too. The content span existing at
        // the shrunk range is what confirms this is a real formatted run and
        // not two coincidental delimiter-shaped characters around ordinary
        // text.
        if selection.length > 2 * delimLen {
            let inner = NSRange(location: selection.location + delimLen,
                                length: selection.length - 2 * delimLen)
            if sameKindSpans.contains(where: { $0.range == inner }) {
                return unwrap(source, contentRange: inner, delimLen: delimLen)
            }
        }

        // Any OTHER overlap with a same-kind span (or its flanking
        // delimiters) is a partial match — no-op per policy above.
        for span in sameKindSpans {
            let full = NSRange(location: span.range.location - delimLen,
                               length: span.range.length + 2 * delimLen)
            if NSIntersectionRange(full, selection).length > 0 { return nil }
        }

        // Clean, unformatted (for this kind) selection — wrap, then verify
        // the result actually round-trips before handing it back.
        var wrapped = ns.substring(to: selection.location)
        wrapped += delim
        wrapped += ns.substring(with: selection)
        wrapped += delim
        wrapped += ns.substring(from: selection.upperBound)
        let newSelection = NSRange(location: selection.location + delimLen, length: selection.length)

        guard NoteDecoration.spans(wrapped).contains(where: { $0.kind == kind && $0.range == newSelection })
        else { return nil }

        return Result(source: wrapped, selection: newSelection)
    }

    private static func unwrap(_ source: String, contentRange: NSRange, delimLen: Int) -> Result {
        let ns = source as NSString
        var result = ns.substring(to: contentRange.location - delimLen)
        result += ns.substring(with: contentRange)
        result += ns.substring(from: contentRange.upperBound + delimLen)
        return Result(source: result,
                      selection: NSRange(location: contentRange.location - delimLen, length: contentRange.length))
    }

    // MARK: - Link (own grammar — NoteDecoration doesn't model `[text](url)`)

    private static let linkPattern = try! NSRegularExpression(pattern: #"^\[([^\]]*)\]\(([^)]*)\)$"#)
    private static let closingLinkPattern = try! NSRegularExpression(pattern: #"^\]\([^)]*\)"#)

    private static func toggleLink(_ source: String, selection: NSRange) -> Result? {
        let ns = source as NSString

        // Case (b): selection is exactly the whole "[text](url)".
        let outer = ns.substring(with: selection)
        let outerNS = outer as NSString
        if let match = linkPattern.firstMatch(in: outer, range: NSRange(location: 0, length: outerNS.length)) {
            let text = outerNS.substring(with: match.range(at: 1))
            let result = ns.substring(to: selection.location) + text + ns.substring(from: selection.upperBound)
            return Result(source: result,
                         selection: NSRange(location: selection.location, length: (text as NSString).length))
        }

        // Case (a): selection is exactly the text INSIDE an existing
        // "[text](url)" — "[" immediately before, "](url)" immediately after.
        if selection.location >= 1, ns.substring(with: NSRange(location: selection.location - 1, length: 1)) == "[" {
            let tail = ns.substring(from: selection.upperBound)
            let tailNS = tail as NSString
            if let m = closingLinkPattern.firstMatch(in: tail, range: NSRange(location: 0, length: tailNS.length)),
               m.range.location == 0 {
                let result = ns.substring(to: selection.location - 1)
                    + ns.substring(with: selection)
                    + ns.substring(from: selection.upperBound + m.range.length)
                return Result(source: result,
                             selection: NSRange(location: selection.location - 1, length: selection.length))
            }
        }

        // Otherwise: wrap fresh, selecting the URL placeholder slot.
        let prefix = ns.substring(to: selection.location)
        let head = prefix + "[" + ns.substring(with: selection) + "]("
        let urlStart = (head as NSString).length
        let result = head + linkURLPlaceholder + ")" + ns.substring(from: selection.upperBound)
        return Result(source: result,
                     selection: NSRange(location: urlStart, length: (linkURLPlaceholder as NSString).length))
    }
}
