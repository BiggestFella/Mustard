import Foundation

/// SwiftData-free value for one indexable note — mapped from `NoteIndexEntry` at the
/// call site so `match` stays pure/testable.
public struct NoteSearchEntry: Equatable {
    public let project: String
    public let relativePath: String
    public let title: String
    public let content: String
    public init(project: String, relativePath: String, title: String, content: String) {
        self.project = project; self.relativePath = relativePath
        self.title = title; self.content = content
    }
}

public struct NoteSearchHit: Equatable, Identifiable {
    public let project: String
    public let relativePath: String
    public let title: String
    /// First matching body line, only for body-only hits (title/filename hits show the title row already).
    public let snippet: String?
    public var id: String { project + "/" + relativePath }
}

/// Full-text search over the note index (Notes polish pack). Ranks title > filename >
/// body, then alphabetical; body-only hits carry a one-line snippet. Case-insensitive.
public enum NoteSearch {
    public static func match(entries: [NoteSearchEntry], query: String) -> [NoteSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        struct Ranked { let hit: NoteSearchHit; let rank: Int }
        var ranked: [Ranked] = []
        for e in entries {
            let filename = (e.relativePath as NSString).lastPathComponent
            let inTitle = e.title.lowercased().contains(needle)
            let inFilename = filename.lowercased().contains(needle)
            let bodyLine = firstMatchingLine(in: e.content, needle: needle)
            guard inTitle || inFilename || bodyLine != nil else { continue }
            let rank = inTitle ? 0 : (inFilename ? 1 : 2)
            let snippet = (inTitle || inFilename) ? nil : bodyLine
            ranked.append(Ranked(
                hit: NoteSearchHit(project: e.project, relativePath: e.relativePath,
                                   title: e.title, snippet: snippet),
                rank: rank))
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.hit.title.localizedCaseInsensitiveCompare(b.hit.title) == .orderedAscending
        }.map(\.hit)
    }

    private static func firstMatchingLine(in content: String, needle: String) -> String? {
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.lowercased().contains(needle) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
