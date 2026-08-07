import Foundation

/// First non-empty body lines of a note, for the wikilink hover preview (Notes polish
/// pack). Frontmatter-stripped (reuses the shared `Frontmatter` parser, as
/// BacklinkSnippets/NoteMetadata do). Pure — no view/clock deps.
public enum NotePreview {
    public static func excerpt(content: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let body = Frontmatter.parse(content).body
        var lines: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.count >= maxLines { break }
        }
        return lines.joined(separator: "\n")
    }
}
