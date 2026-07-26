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

    public static func plan(oldRelativePath: String, oldContent: String, newTitle: String,
                            others: [(relativePath: String, content: String)],
                            existingPaths: [String]) -> Plan {
        let newRelativePath = NoteCreation.relativePath(title: newTitle, existing: existingPaths)
        let newTarget = NoteCreation.displayName(newTitle)
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
        return Plan(oldRelativePath: oldRelativePath, newRelativePath: newRelativePath,
                    renamedNoteContent: retitle(content: oldContent, newTitle: newTitle),
                    linkEdits: edits)
    }

    /// Updates the renamed note's own frontmatter `title:` and first ATX heading.
    public static func retitle(content: String, newTitle: String) -> String {
        let name = NoteCreation.displayName(newTitle)
        var lines = content.components(separatedBy: "\n")
        if lines.first == "---" {
            var i = 1
            while i < lines.count, lines[i] != "---" {
                if lines[i].hasPrefix("title:") { lines[i] = "title: \(NoteCreation.yamlEscaped(name))"; break }
                i += 1
            }
        }
        for i in lines.indices {
            if let hashes = atxHeadingPrefix(lines[i]) { lines[i] = "\(hashes) \(name)"; break }
        }
        return lines.joined(separator: "\n")
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
