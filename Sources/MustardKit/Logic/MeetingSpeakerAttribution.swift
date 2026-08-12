import Foundation

/// A detected verbal handoff in a meeting transcript (BAK-335): the
/// recurring standup protocol ("over to Fahad", "I shall pass it back to
/// Alex", "back to you, Jerry") that Mustard's meeting channel can key
/// speaker attribution off deterministically, instead of guessing. `name` is
/// the raw word token(s) captured after the handoff phrase — exactly as the
/// transcript rendered them (case as transcribed, no candidate judging
/// applied yet).
public struct Handoff: Equatable, Sendable {
    public let segmentIndex: Int
    public let name: String

    public init(segmentIndex: Int, name: String) {
        self.segmentIndex = segmentIndex
        self.name = name
    }
}

/// Speaker attribution over a meeting-channel transcript, built around one
/// non-negotiable rule: **unattributed is a first-class state**. Where
/// Notion-style tools invent a speaker from thin air, Mustard only ever
/// attributes a span when an explicit verbal handoff names someone who
/// matches a known candidate; anything else stays `nil`. Acoustic
/// diarization is deliberately out of scope — this is pure text pattern
/// matching over the standup's spoken handoff convention.
public enum MeetingSpeakerAttribution {
    /// One name token: starts with a letter, may contain internal
    /// apostrophes/hyphens ("O'Brien", "Jean-Luc"). Transcription may
    /// lowercase everything — case is judged later, by candidate matching,
    /// not by this pattern.
    private static let namePattern = "[A-Za-z][A-Za-z'-]*"

    /// The five handoff phrasings this feature ships, and only these —
    /// anything fuzzier ("X, if you've got a sec" / "you want to drive?") is
    /// deliberately excluded because it invites false positives on a
    /// principle where a wrong guess is worse than no attribution at all.
    /// Ordered so a more specific alternative ("pass it back to") is offered
    /// before a looser one that could also start matching the same words
    /// ("pass it/that over to"); this only matters when two alternatives
    /// could both start at the same position, which these five never do
    /// except within the "pass …" family.
    private static let handoffRegex: NSRegularExpression = {
        let phrase = [
            #"pass\s+it\s+(?:back\s+)?to"#,
            #"pass\s+(?:it|that)\s+over\s+to"#,
            #"hand(?:ing)?\s+(?:it\s+)?over\s+to"#,
            #"back\s+to\s+you,?"#,
            #"over\s+to"#,
        ].joined(separator: "|")
        let pattern = "(?:\(phrase))\\s+(\(namePattern))(?:\\s+(\(namePattern)))?"
        // The pattern above is built entirely from the literals in this
        // file — a failure here would be a programmer error, not runtime
        // input, so a crash-on-failure `try!` is the right call.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Scans every text for the five explicit handoff phrasings, in order.
    /// A single text may contain more than one handoff (rare, but not
    /// disallowed); matches never overlap, so a longer phrase that contains
    /// a shorter one as a substring ("pass it over to X" contains "over to
    /// X") is reported exactly once, for the longer phrase, because
    /// `enumerateMatches` resumes scanning only after each match's end.
    public static func detectHandoffs(texts: [String]) -> [Handoff] {
        var result: [Handoff] = []
        for (index, text) in texts.enumerated() {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            handoffRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, let name = extractedName(from: match, in: text) else { return }
                result.append(Handoff(segmentIndex: index, name: name))
            }
        }
        return result
    }

    /// One entry per input text: the span AFTER a handoff whose name
    /// fuzzy-matches a candidate is attributed to that candidate's canonical
    /// form, until the next handoff. The handoff's own segment stays with
    /// the PREVIOUS span — the person saying "over to Fahad" is not Fahad.
    /// A handoff whose name matches no candidate ENDS the previous span and
    /// opens an unattributed one; it never falls back to carrying the
    /// previous speaker forward. Everything before the first handoff is
    /// unattributed.
    public static func attribute(texts: [String], candidates: [String]) -> [String?] {
        let handoffs = detectHandoffs(texts: texts)
        var result = [String?](repeating: nil, count: texts.count)
        var currentSpeaker: String?
        var handoffIndex = 0

        for index in texts.indices {
            // Whatever speaker was active BEFORE this line's own handoff(s)
            // (if any) take effect — this is what keeps the handoff segment
            // itself attributed to the previous speaker.
            result[index] = currentSpeaker
            while handoffIndex < handoffs.count, handoffs[handoffIndex].segmentIndex == index {
                currentSpeaker = matchedCandidate(for: handoffs[handoffIndex].name, in: candidates)
                handoffIndex += 1
            }
        }
        return result
    }

    // MARK: - Candidate matching

    /// First candidate (in the order given) that fuzzy-matches `name`, or
    /// nil if none does — the caller records that as an unattributed span,
    /// never a guess.
    private static func matchedCandidate(for name: String, in candidates: [String]) -> String? {
        candidates.first { fuzzyMatches(name, candidate: $0) }
    }

    /// Case-insensitive exact match against the candidate's full name or
    /// its first name, OR a symmetric prefix match (either string a prefix
    /// of the other) against the candidate's first name, gated at 3
    /// characters so short common words never accidentally qualify.
    static func fuzzyMatches(_ name: String, candidate: String) -> Bool {
        let extracted = name.lowercased()
        let full = candidate.lowercased()
        let firstName = String(full.split(separator: " ").first ?? Substring(full))

        if extracted == full || extracted == firstName { return true }
        guard extracted.count >= 3, firstName.count >= 3 else { return false }
        return extracted.hasPrefix(firstName) || firstName.hasPrefix(extracted)
    }

    // MARK: - Extraction

    private static func extractedName(from match: NSTextCheckingResult, in text: String) -> String? {
        guard let firstRange = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[firstRange])
        if match.range(at: 2).location != NSNotFound,
           let secondRange = Range(match.range(at: 2), in: text) {
            name += " " + text[secondRange]
        }
        // Defensive: the character class above already excludes punctuation,
        // but strip any trailing non-letter characters in case the pattern
        // ever changes.
        while let last = name.last, !last.isLetter {
            name.removeLast()
        }
        return name.isEmpty ? nil : name
    }
}
