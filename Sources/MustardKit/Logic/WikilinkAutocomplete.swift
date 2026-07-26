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
        let needle = query.lowercased()
        guard !needle.isEmpty else { return titles }
        var prefix: [String] = [], substring: [String] = []
        for t in titles {
            let tl = t.lowercased()
            if tl.hasPrefix(needle) { prefix.append(t) }
            else if tl.contains(needle) { substring.append(t) }
        }
        let az: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return prefix.sorted(by: az) + substring.sorted(by: az)
    }
}
