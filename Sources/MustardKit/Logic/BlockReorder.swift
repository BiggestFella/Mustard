import Foundation

/// Pure block drag-reorder for the live editor (Craft spec, 2b): the ONLY function
/// that rewrites note source for a move. Operates on NoteDecoration's total
/// partition; the frontmatter block is never moveable and never displaced.
public enum BlockReorder {

    /// Moveable blocks = `NoteDecoration.blocks` minus any frontmatter block.
    /// `from`/`to` index that array; `to` is the destination slot AFTER removal
    /// (standard reorder semantics). Out-of-range or from == to → source unchanged,
    /// byte-identical. Every non-blank line of the input appears exactly once in
    /// the output; separator hygiene (below) is the one permitted adjustment.
    ///
    /// Separator rule (the honest wrinkle): each block slice carries its trailing
    /// blank lines, so a naive slice permutation would drag separators around with
    /// their blocks — and the final block, which may lack a trailing newline
    /// entirely, would fuse with whatever follows it. Instead each slice splits
    /// into (content, blank-line tail); CONTENT moves, TAILS stay at their
    /// document position — the blank-line rhythm of the note is a property of the
    /// document, not of the paragraph being dragged. The single byte-level
    /// adjustment on top: content that lacks a line terminator (only ever the
    /// original final block) gains "\n" when it lands anywhere but last, so lines
    /// never fuse. Both behaviours are byte-pinned in BlockReorderTests; content
    /// lines are never touched.
    public static func move(_ source: String, from: Int, to: Int) -> String {
        let ns = source as NSString
        let all = NoteDecoration.blocks(source)
        // Frontmatter is only ever the partition's first block; it is emitted
        // verbatim (its own trailing blanks included) and indices skip it.
        let frontmatter = all.first.flatMap { $0.isFrontmatter ? $0 : nil }
        let moveable = all.filter { !$0.isFrontmatter }

        guard from != to,
              from >= 0, from < moveable.count,
              to >= 0, to < moveable.count
        else { return source }

        let parts = moveable.map { splitTrailingBlanks(ns.substring(with: $0.range)) }
        let tails = parts.map(\.tail)              // positional — never permuted
        var contents = parts.map(\.content)
        let moved = contents.remove(at: from)
        contents.insert(moved, at: to)

        var result = frontmatter.map { ns.substring(with: $0.range) } ?? ""
        for index in 0..<contents.count {
            var piece = contents[index]
            // Terminator hygiene: a non-final content without its own line ending
            // (the original EOF block moved off the end) gains "\n" so it can't
            // fuse with the next block's first line. Check the last unicode
            // scalar, not a Character suffix: "\r\n" is a single grapheme
            // cluster, so `hasSuffix("\n")` is false for CRLF-terminated
            // content and would bolt a spurious lone "\n" onto CRLF blocks.
            if index < contents.count - 1, !piece.isEmpty,
               piece.unicodeScalars.last != "\n", piece.unicodeScalars.last != "\r" {
                piece += "\n"
            }
            result += piece + tails[index]
        }
        return result
    }

    /// Splits a block slice into (content, maximal trailing run of blank lines).
    /// "Blank" matches NoteDecoration's rule (whitespace-only after trimming), and
    /// tail bytes are preserved verbatim — CRLF blanks stay CRLF. Interior blank
    /// lines (inside a fence) are untouched: only the run at the very end splits.
    ///
    /// Internal (not `private`): `BlockTransform` (Phase 3 / BAK-252) reuses this
    /// exact algorithm so a "turn into" splice's untouched trailing-blank tail
    /// matches `move`'s separator-hygiene rule byte-for-byte instead of a second,
    /// possibly-drifting reimplementation.
    static func splitTrailingBlanks(_ slice: String) -> (content: String, tail: String) {
        let ns = slice as NSString
        var location = 0
        var contentEnd = 0
        while location < ns.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                contentEnd = end
            }
            location = end
        }
        return (content: ns.substring(to: contentEnd), tail: ns.substring(from: contentEnd))
    }
}
