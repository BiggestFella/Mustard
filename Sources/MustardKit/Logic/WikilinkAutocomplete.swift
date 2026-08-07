import Foundation

/// `[[` autocomplete for the note editor (Notes polish pack). Detects the open
/// wikilink query at the caret and ranks note-title candidates. Pure; the coordinator
/// drives the popup (mirroring the `/` SlashMenu path) and splices `[[Title]]` through
/// the existing byte-pinned insert path.
public enum WikilinkAutocomplete {
    public struct Query: Equatable {
        /// Covers "[[" + typed text, in UTF-16 coords of the whole document `text`.
        public let range: NSRange
        public let text: String
        public init(range: NSRange, text: String) { self.range = range; self.text = text }
    }

    /// The active `[[…` query at the caret: the nearest "[[" to the left of the caret
    /// on the same line with no intervening "]]" or newline, and no "]" in the query.
    /// nil when the caret is not inside an open, unclosed wikilink.
    public static func activeQuery(text: String, caretUTF16: Int) -> Query? {
        let ns = text as NSString
        guard caretUTF16 >= 2, caretUTF16 <= ns.length else { return nil }
        var i = caretUTF16 - 1
        while i >= 1 {
            let pair = ns.substring(with: NSRange(location: i - 1, length: 2))
            if pair.contains("\n") || pair == "]]" { return nil }
            if pair == "[[" {
                let open = i - 1
                let queryRange = NSRange(location: open + 2, length: caretUTF16 - (open + 2))
                let q = ns.substring(with: queryRange)
                if q.contains("[") || q.contains("]") || q.contains("\n") { return nil }
                return Query(range: NSRange(location: open, length: caretUTF16 - open), text: q)
            }
            i -= 1
        }
        return nil
    }

    /// Titles matching `query`: prefix matches first (case-insensitive), then substring
    /// matches, each group alphabetical. Empty query returns `titles` unchanged.
    public static func candidates(query: String, titles: [String]) -> [String] {
        rank(query: query, candidates: titles.map { LinkCandidate(title: $0, stem: $0) })
            .map(\.title)
    }

    /// One pickable note: `title` is what the row displays (frontmatter/heading
    /// title), `stem` is the filename stem — the thing wikilinks actually resolve
    /// by (`WikilinkIndex.resolve` matches path/filename, never titles). Splicing
    /// the display title mints dangling links whenever the two differ (final-review
    /// finding #1 — the same trap NoteRename's C1 fix documents).
    public struct LinkCandidate: Equatable {
        public let title: String
        public let stem: String
        public init(title: String, stem: String) { self.title = title; self.stem = stem }
    }

    /// `candidates` with stems attached — same ranking rules, applied to titles.
    public static func rank(query: String, candidates: [LinkCandidate]) -> [LinkCandidate] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return candidates }
        var prefix: [LinkCandidate] = [], substring: [LinkCandidate] = []
        for c in candidates {
            let tl = c.title.lowercased()
            if tl.hasPrefix(needle) { prefix.append(c) }
            else if tl.contains(needle) { substring.append(c) }
        }
        let az: (LinkCandidate, LinkCandidate) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return prefix.sorted(by: az) + substring.sorted(by: az)
    }

    /// The exact text a pick splices: the resolvable stem as the target, keeping
    /// the display title as an alias only when the two differ.
    public static func insertion(for candidate: LinkCandidate) -> String {
        candidate.stem == candidate.title
            ? "[[\(candidate.stem)]]"
            : "[[\(candidate.stem)|\(candidate.title)]]"
    }

    /// Filename stem of a vault-relative path — THE wikilink resolution key.
    public static func stem(ofPath path: String) -> String {
        (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
    }
}
