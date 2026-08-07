import Foundation

/// Filename + stub rules for "+" note creation (BAK-153). New notes land in the
/// project's notes/ folder; collisions get " 2", " 3"… (case-insensitive against
/// existing paths). The stub's frontmatter reserves Phase B's task_id/area fields
/// a clean landing spot (spec: Frontmatter decision #8).
public enum NoteCreation {
    /// The sanitized name's UTF-8 byte budget. APFS caps a filename component at
    /// 255 bytes; over that `write` fails ENAMETOOLONG (swallowed by the caller's
    /// try?). 200 leaves headroom for ".md" plus collision counters, so a counter
    /// can never push the filename over the limit.
    private static let maxNameBytes = 200

    /// Path-separator / colon characters are each replaced by `-` so the title
    /// can't escape `notes/` or break the path; other characters (incl. the space
    /// after `My:`) are preserved. Leading dots are stripped — `notes/.hidden.md`
    /// would be invisible to `notePaths()` (skipsHiddenFiles), vanishing from the
    /// sidebar AND from this collision check, so re-creating would silently
    /// overwrite. Empty/whitespace (or dots-only) title falls back to "Untitled"
    /// — matching `stub` so filename and heading agree.
    public static func relativePath(title: String, existing: [String]) -> String {
        let name = sanitizedName(title)
        let existingLowered = Set(existing.map { $0.lowercased() })
        // First candidate is bare; collisions escalate " 2", " 3", …
        var counter = 1
        while true {
            let candidate = counter == 1 ? "notes/\(name).md" : "notes/\(name) \(counter).md"
            if !existingLowered.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// The frontmatter title is double-quoted (internal `\` and `"` escaped) only
    /// when YAML needs it — `:`/`#`/`"` anywhere, or a leading `-`/`[`/`{` — so
    /// plain titles stay byte-identical. The `# heading` line always carries the
    /// raw (trimmed, newline-folded) title unquoted.
    public static func stub(title: String) -> String {
        let name = displayName(title)
        return "---\ntitle: \(yamlEscaped(name))\ntags: []\n---\n\n# \(name)\n"
    }

    private static func sanitizedName(_ title: String) -> String {
        var name = displayName(title)
        for separator in ["/", ":", "\\"] {
            name = name.replacingOccurrences(of: separator, with: "-")
        }
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Untitled" }   // dots-only title
        let clamped = clampedToNameBudget(name)
        // A single grapheme cluster bigger than the whole budget clamps to "" —
        // which would yield hidden "notes/.md". Re-apply the fallback after clamping.
        return clamped.isEmpty ? "Untitled" : clamped
    }

    /// Trims, folds internal newlines (multi-line paste) to single spaces, and
    /// falls back to "Untitled" when nothing is left. Public so `NoteRename` can
    /// retitle a note's frontmatter/heading with identical rules.
    public static func displayName(_ title: String) -> String {
        let folded = title
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return folded.isEmpty ? "Untitled" : folded
    }

    /// Truncates to `maxNameBytes` UTF-8 bytes on a character boundary (never
    /// splitting a scalar/grapheme), applied BEFORE the collision counter so
    /// counters can't push the filename over the APFS limit.
    private static func clampedToNameBudget(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        var clamped = ""
        var bytes = 0
        for character in name {
            bytes += character.utf8.count
            guard bytes <= maxNameBytes else { break }
            clamped.append(character)
        }
        // Truncation can strand a trailing space — trim it. The caller re-applies
        // the Untitled fallback: one over-budget grapheme cluster clamps to "".
        return clamped.trimmingCharacters(in: .whitespaces)
    }

    /// Quotes when the bare value would break a real YAML parser (Obsidian flags
    /// the whole properties block): `:` mappings, `#` comments, stray quotes, or
    /// a leading list/flow indicator. Public so `NoteRename` can render a retitled
    /// note's frontmatter `title:` value with identical rules.
    public static func yamlEscaped(_ title: String) -> String {
        let needsQuoting = title.contains(":") || title.contains("#") || title.contains("\"")
            || title.hasPrefix("-") || title.hasPrefix("[") || title.hasPrefix("{")
        guard needsQuoting else { return title }
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
