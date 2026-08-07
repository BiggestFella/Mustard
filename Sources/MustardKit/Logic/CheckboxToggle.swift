import Foundation

/// Toggling a task checkbox in place — the one mutation behind the clickable
/// checkbox glyph the Notes editor draws over `- [ ] `/`- [x] ` lines. Pure and
/// length-preserving: it flips ONLY the single character between the brackets
/// (`[ ]` ⇄ `[x]`), so every other byte — and any caret/selection — stays put.
/// `NoteDecoration` stays read-only (its markdown-as-truth doc forbids a rewrite
/// API there); this small mutator lives on its own.
public enum CheckboxToggle {

    /// Toggle the checkbox on the todo line containing `location` (a caret or a
    /// click's character index). Returns the rewritten source plus a collapsed
    /// selection to restore, or `nil` if that line has no checkbox.
    public static func toggled(_ source: String, at location: Int) -> (source: String, selection: NSRange)? {
        let ns = source as NSString
        guard location >= 0, location <= ns.length else { return nil }

        let blocks = NoteDecoration.blocks(source)
        guard let block = blocks.first(where: { NSLocationInRange(location, $0.range) }) ?? blocks.last
        else { return nil }
        guard let (markerRange, glyph) = NoteDecoration.blockGlyph(source, of: block),
              case .checkbox(let checked) = glyph else { return nil }

        // The "[ ]"/"[x]"/"[X]" token sits inside the marker range; flip its
        // middle character. 1-for-1 replacement keeps the string length (and thus
        // `location`) valid.
        let markerText = ns.substring(with: markerRange) as NSString
        let bracket = markerText.range(of: "[")
        guard bracket.location != NSNotFound else { return nil }
        let midRange = NSRange(location: markerRange.location + bracket.location + 1, length: 1)
        guard midRange.upperBound <= ns.length else { return nil }

        let newSource = ns.replacingCharacters(in: midRange, with: checked ? " " : "x")
        let clamped = min(location, (newSource as NSString).length)
        return (newSource, NSRange(location: clamped, length: 0))
    }
}
