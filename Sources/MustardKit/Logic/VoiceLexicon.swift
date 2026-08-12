import Foundation

/// Derives contextual-vocabulary terms for transcription biasing (BAK-334).
/// Standup speech is full of proper nouns SpeechAnalyzer has never seen —
/// client names ("Thales" → "Talus", "Sandvik" → "Sandvic"), colleague names
/// ("Fahad" → "the 2 for heart"), project codes ("DLA", "CDSB") — while
/// Mustard already holds exactly that vocabulary in its own data: areas,
/// task lists, task titles, and meeting action owners. This type is PURE —
/// it takes plain strings already fetched by the caller (see
/// `Voice/VoiceLexiconSource.swift` for the SwiftData-facing assembly) and
/// returns the ordered, deduped, bounded term list that gets handed to a
/// transcription session at capture/meeting start.
public enum VoiceLexicon {
    /// The macOS 27 Speech SDK's `AnalysisContext.contextualStrings` does not
    /// document a numeric limit (verified against the beta SDK's
    /// swiftinterface — see the BAK-334 run's task.md for the exact grep
    /// evidence). This cap exists to keep the derived list itself bounded
    /// and deterministic, independent of `VoiceContextVocabulary.defaultLimit`
    /// (64) which still applies at the session-forwarding boundary.
    public static let defaultCap = 100

    /// Terms too short to disambiguate anything ("A", "Ok") or implausibly
    /// long to be a spoken vocabulary hint are dropped regardless of source.
    private static let minLength = 2
    private static let maxLength = 40

    /// Small, curated stopword list for the title-derived heuristic — common
    /// task-title verbs/articles that would otherwise repeat across many
    /// titles and get mistaken for a recurring proper noun.
    static let titleStopwords: Set<String> = [
        "the", "a", "an", "and", "for", "with", "this", "that", "new",
        "fix", "fixed", "fixes", "add", "added", "adds",
        "update", "updated", "updates", "remove", "removed", "removes",
        "bug", "task", "feature", "support", "improve", "improved",
        "refactor", "refactored", "review", "docs", "test", "tests", "testing",
        "on", "in", "of", "to", "at", "from", "by", "as",
        "is", "are", "was", "were", "be", "it", "its",
        "our", "your", "my", "not", "no", "yes",
        "all", "some", "any", "one", "two", "three"
    ]

    /// Rank order (highest priority first): user-entered terms are verbatim
    /// and always survive truncation; then areas, task lists, meeting-action
    /// owners, and finally terms mined from task titles. Case-insensitive
    /// dedup keeps the first occurrence's casing; length-out-of-bounds terms
    /// are dropped; the result is truncated to `cap`.
    public static func terms(
        areas: [String] = [],
        taskLists: [String] = [],
        taskTitles: [String] = [],
        proposalOwners: [String] = [],
        userTerms: [String] = [],
        cap: Int = defaultCap
    ) -> [String] {
        var ordered: [String] = []
        ordered.append(contentsOf: userTerms)
        ordered.append(contentsOf: areas)
        ordered.append(contentsOf: taskLists)
        ordered.append(contentsOf: proposalOwners)
        ordered.append(contentsOf: titleDerivedTerms(from: taskTitles))
        return dedupedAndBounded(ordered, cap: cap)
    }

    /// Splits a persisted "custom vocabulary" setting (newline- or
    /// comma-separated, see `Voice/VoiceLexiconSource.swift`) into terms.
    /// Empty entries (blank lines, trailing commas) are dropped.
    public static func parseUserTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Dedup + bounds

    private static func dedupedAndBounded(_ candidates: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minLength, trimmed.count <= maxLength else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            kept.append(trimmed)
            if kept.count == cap { break }
        }
        return kept
    }

    // MARK: - Title-derived terms (deterministic heuristic)

    /// Tokenizes every title, then keeps a token when it either (a) carries
    /// an uppercase letter after position 0 — acronym/code-style ("DLA",
    /// "CDSB", "iOS-style") — kept even as a singleton, or (b) is an
    /// ordinarily-capitalized word appearing at least twice across all
    /// titles and not in `titleStopwords` — the repeated-proper-noun case
    /// ("Thales" mentioned in two different standup task titles).
    static func titleDerivedTerms(from titles: [String]) -> [String] {
        var acronymTokens: [String] = []
        var seenAcronymKeys = Set<String>()

        var occurrenceCounts: [String: Int] = [:]
        var firstCasing: [String: String] = [:]
        var firstSeenOrder: [String] = []

        for title in titles {
            for token in tokenize(title) {
                if hasUppercaseAfterFirstCharacter(token) {
                    let key = token.lowercased()
                    if seenAcronymKeys.insert(key).inserted {
                        acronymTokens.append(token)
                    }
                    continue
                }
                guard let first = token.first, first.isUppercase else { continue }
                let key = token.lowercased()
                occurrenceCounts[key, default: 0] += 1
                if firstCasing[key] == nil {
                    firstCasing[key] = token
                    firstSeenOrder.append(key)
                }
            }
        }

        let repeatedCapitalized = firstSeenOrder.compactMap { key -> String? in
            guard (occurrenceCounts[key] ?? 0) >= 2, !titleStopwords.contains(key) else { return nil }
            return firstCasing[key]
        }

        return acronymTokens + repeatedCapitalized
    }

    /// Splits on any character that is neither alphanumeric nor a hyphen, so
    /// compound codes ("iOS-style") stay one token while punctuation
    /// ("permission," "Fahad's") never sticks to a word. Leading/trailing
    /// hyphens left over from adjacent punctuation are trimmed off.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "-" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(trimHyphens(current))
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(trimHyphens(current)) }
        return tokens.filter { !$0.isEmpty }
    }

    private static func trimHyphens(_ token: String) -> String {
        var slice = Substring(token)
        while slice.first == "-" { slice = slice.dropFirst() }
        while slice.last == "-" { slice = slice.dropLast() }
        return String(slice)
    }

    private static func hasUppercaseAfterFirstCharacter(_ token: String) -> Bool {
        guard token.count > 1 else { return false }
        return token.dropFirst().contains { $0.isUppercase }
    }
}
