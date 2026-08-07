import Foundation

/// Link-aware note rename (Notes polish pack). Pure planning: computes the new path
/// (NoteCreation collision rules), retitles the renamed note's own frontmatter/heading,
/// and rewrites inbound `[[links]]` across other notes. Reuses THE shared wikilink
/// regex (`WikilinkSyntax`) so every link form is covered; skips fenced code, as the
/// index does. Execution (move/write/reindex) lives in NotesView.
public enum NoteRename {
    public struct LinkEdit: Equatable {
        public let relativePath: String
        public let newContent: String
    }
    public struct Plan: Equatable {
        public let oldRelativePath: String
        public let newRelativePath: String
        public let renamedNoteContent: String
        public let linkEdits: [LinkEdit]
    }

    /// `existingPaths` MUST exclude `oldRelativePath` (the caller drops it), so a
    /// pure retitle of the same note doesn't collide-suffix against itself.
    public static func plan(oldRelativePath: String, oldContent: String, newTitle: String,
                            others: [(relativePath: String, content: String)],
                            existingPaths: [String]) -> Plan {
        let newRelativePath = NoteCreation.relativePath(title: newTitle, existing: existingPaths)
        // Links resolve by FILENAME STEM, not the display title — so the rewrite target
        // is the actual new file's stem (which carries any collision counter/sanitization
        // NoteCreation applied). Using displayName here would misroute links on a name
        // collision or break them on sanitized/wikilink-illegal titles (review C1).
        let newTarget = ((newRelativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        // Resolver over the CURRENT path set (old path + others) identifies inbound links.
        let allPaths = [oldRelativePath] + others.map(\.relativePath)
        let resolve = WikilinkIndex.resolver(paths: allPaths)
        var edits: [LinkEdit] = []
        for note in others {
            let rewritten = rewrite(content: note.content, resolve: resolve,
                                    oldPath: oldRelativePath, newTarget: newTarget)
            if rewritten != note.content {
                edits.append(LinkEdit(relativePath: note.relativePath, newContent: rewritten))
            }
        }
        // The renamed note's own content: retitle, then rewrite SELF-links too
        // ([[Old]] inside Old.md dangles after the move otherwise — final-review #5).
        let renamedContent = rewrite(content: retitle(content: oldContent, newTitle: newTitle),
                                     resolve: resolve, oldPath: oldRelativePath,
                                     newTarget: newTarget)
        return Plan(oldRelativePath: oldRelativePath, newRelativePath: newRelativePath,
                    renamedNoteContent: renamedContent,
                    linkEdits: edits)
    }

    /// Updates the renamed note's own frontmatter `title:` and first body ATX heading.
    /// Frontmatter- and fence-aware and CRLF-tolerant, so the heading scan matches
    /// `WikilinkIndex.firstHeading` (which titles off the stripped body) rather than
    /// clobbering a `#` line inside frontmatter or a leading code fence (review I2/I3).
    public static func retitle(content: String, newTitle: String) -> String {
        let name = NoteCreation.displayName(newTitle)
        var lines = content.components(separatedBy: "\n")

        // Frontmatter block only when the first line is exactly "---" (CRLF-tolerant).
        var bodyStart = 0
        if lineIsFence(lines.first) {
            var i = 1
            var closed = false
            var titleSet = false
            while i < lines.count {
                if lineIsFence(lines[i]) { closed = true; i += 1; break }
                if !titleSet, lines[i].hasPrefix("title:") {
                    let cr = lines[i].hasSuffix("\r") ? "\r" : ""
                    lines[i] = "title: \(NoteCreation.yamlEscaped(name))\(cr)"
                    titleSet = true
                }
                i += 1
            }
            bodyStart = closed ? i : lines.count   // unterminated frontmatter → no body scan
        }

        // First ATX heading in the BODY, skipping fenced code (trimmed like firstHeading).
        var inFence = false
        var j = bodyStart
        while j < lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); j += 1; continue }
            if !inFence, let hashes = atxHeadingPrefix(trimmed) {
                let cr = lines[j].hasSuffix("\r") ? "\r" : ""
                lines[j] = "\(hashes) \(name)\(cr)"
                break
            }
            j += 1
        }
        return lines.joined(separator: "\n")
    }

    /// A "---" frontmatter fence line, tolerating a trailing CR from CRLF files.
    private static func lineIsFence(_ line: String?) -> Bool {
        guard let line else { return false }
        return line == "---" || line == "---\r"
    }

    /// Rewrites wikilink occurrences whose target resolves to `oldPath`, swapping only
    /// the target segment (bang / `#heading` / `|alias` preserved). Skips fenced code.
    public static func rewrite(content: String, resolve: (String) -> String?,
                               oldPath: String, newTarget: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in content.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle(); out.append(raw); continue
            }
            out.append(inFence ? raw : rewriteLine(raw, resolve: resolve, oldPath: oldPath, newTarget: newTarget))
        }
        return out.joined(separator: "\n")
    }

    private static func rewriteLine(_ line: String, resolve: (String) -> String?,
                                    oldPath: String, newTarget: String) -> String {
        let ns = line as NSString
        let matches = WikilinkSyntax.regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        var result = line
        for match in matches.reversed() {   // right-to-left keeps leftward ranges valid
            let targetRange = match.range(at: 1)
            guard targetRange.location != NSNotFound else { continue }
            let target = ns.substring(with: targetRange).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, resolve(target) == oldPath else { continue }
            let full = ns.substring(with: match.range)
            let bang = full.hasPrefix("!") ? "!" : ""
            let hRange = match.range(at: 2)
            let heading = hRange.location == NSNotFound ? "" : ns.substring(with: hRange)
            let aRange = match.range(at: 4)
            let alias = aRange.location == NSNotFound ? "" : "|" + ns.substring(with: aRange)
            let replacement = "\(bang)[[\(newTarget)\(heading)\(alias)]]"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func atxHeadingPrefix(_ line: String) -> String? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        guard (1...6).contains(count) else { return nil }
        let after = line.index(line.startIndex, offsetBy: count)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(repeating: "#", count: count)
    }
}
