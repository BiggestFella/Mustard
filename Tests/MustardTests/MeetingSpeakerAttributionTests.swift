import XCTest
@testable import MustardKit

/// Verbal-handoff speaker attribution over a meeting transcript (BAK-335).
/// Non-negotiable: unattributed is a first-class state — a handoff whose
/// name doesn't match a known candidate is recorded as NO attribution for
/// the following span, never a guess (the "Liam" case: Notion-style tools
/// invented a speaker that was never a real attendee; Mustard must not).
final class MeetingSpeakerAttributionTests: XCTestCase {

    // MARK: - detectHandoffs: each pattern

    func test_detectHandoffs_overTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["so over to Fahad"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Fahad")])
    }

    func test_detectHandoffs_passItBackTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(
            texts: ["I shall pass it back to Alex"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Alex")])
    }

    func test_detectHandoffs_passItTo_withoutBack() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["pass it to Priya"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Priya")])
    }

    func test_detectHandoffs_passItOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["I'll pass it over to Sam"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Sam")])
    }

    func test_detectHandoffs_passThatOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["pass that over to Noor"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Noor")])
    }

    func test_detectHandoffs_backToYou_withComma() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["back to you, Jerry"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Jerry")])
    }

    func test_detectHandoffs_backToYou_withoutComma() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["back to you Marcus"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Marcus")])
    }

    func test_detectHandoffs_handOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["I'll hand over to Devi"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Devi")])
    }

    func test_detectHandoffs_handItOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["hand it over to Devi"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Devi")])
    }

    func test_detectHandoffs_handingOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["handing over to Devi"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Devi")])
    }

    func test_detectHandoffs_handingItOverTo() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["handing it over to Devi"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Devi")])
    }

    func test_detectHandoffs_caseInsensitive_lowercasedTranscript() {
        // The live transcriber may lowercase everything — the phrase match
        // must still fire; the NAME is captured verbatim either way.
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["OVER TO fahad"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "fahad")])
    }

    // MARK: - Too-fuzzy patterns are deliberately NOT detected

    func test_detectHandoffs_excludesTooFuzzyPhrasing() {
        let texts = [
            "Jerry, if you've got a sec",
            "Alex, you want to drive this one?",
            "Sam, you want to do the update?",
        ]
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(texts: texts).isEmpty)
    }

    // MARK: - Multi-token names

    func test_detectHandoffs_twoTokenName() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["over to Fahad Khan"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Fahad Khan")])
    }

    /// Uses "back to you," rather than bare "over to" — the latter is now
    /// clause-end restricted (review FINDING 1) and would reject this text
    /// for an unrelated reason (trailing content after the name), which
    /// would defeat the point of this test: that the second name token
    /// stops at punctuation regardless.
    func test_detectHandoffs_secondTokenStopsAtPunctuation() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(
            texts: ["back to you, Fahad. Can you take it from here?"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Fahad")])
    }

    // MARK: - Trailing punctuation stripped

    func test_detectHandoffs_trailingCommaStripped() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["back to you, Jerry, thanks"])
        XCTAssertEqual(handoffs.first?.name, "Jerry")
    }

    // MARK: - No handoffs at all

    func test_detectHandoffs_noHandoffs_returnsEmpty() {
        let texts = ["just talking about the sprint", "nothing special here"]
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(texts: texts).isEmpty)
    }

    // MARK: - Empty input

    func test_detectHandoffs_emptyInput_returnsEmpty() {
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(texts: []).isEmpty)
    }

    func test_attribute_emptyInput_returnsEmpty() {
        XCTAssertTrue(MeetingSpeakerAttribution.attribute(texts: [], candidates: ["Fahad"]).isEmpty)
    }

    // MARK: - attribute: the handoff segment stays with the PREVIOUS span

    func test_attribute_handoffSegmentBelongsToPreviousSpeaker_notTheNamedOne() {
        let texts = [
            "let's start the standup",     // 0: unattributed (before any handoff)
            "over to Fahad",                // 1: still unattributed — the SAYER, not Fahad
            "I shipped the release",        // 2: Fahad
        ]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad"])
        XCTAssertEqual(speakers, [nil, nil, "Fahad"])
    }

    // MARK: - attribute: unmatched name -> unattributed span, never guessed

    func test_attribute_unmatchedHandoffName_neverGuessesOrCarriesPreviousSpeaker() {
        // The "Liam" case: a handoff name with no matching candidate must
        // NOT fabricate a speaker, and must NOT keep attributing to whoever
        // was talking before the handoff.
        let texts = [
            "over to Fahad",     // 0: unattributed (handoff line itself)
            "quick update here", // 1: Fahad
            "over to Liam",      // 2: still Fahad (handoff line stays with previous)
            "no updates from me",// 3: unattributed — "Liam" matches no candidate
        ]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad", "Alex"])
        XCTAssertEqual(speakers, [nil, "Fahad", "Fahad", nil])
    }

    // MARK: - attribute: candidate fuzzy rules

    func test_attribute_exactCaseInsensitiveMatch() {
        let texts = ["over to fahad", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad"])
        XCTAssertEqual(speakers, [nil, "Fahad"], "the candidate's canonical form is used, not the transcript casing")
    }

    func test_attribute_matchesCandidateFirstNameOfAFullName() {
        let texts = ["over to Fahad", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad Khan"])
        XCTAssertEqual(speakers, [nil, "Fahad Khan"], "matches on the candidate's first name")
    }

    func test_attribute_prefixMatch_truncatedTranscriptName() {
        // A misheard/truncated capture ("Fah") still prefix-matches "Fahad"
        // at >= 3 chars.
        let texts = ["over to Fah", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad"])
        XCTAssertEqual(speakers, [nil, "Fahad"])
    }

    func test_attribute_prefixMatch_belowThreeChars_doesNotMatch() {
        let texts = ["over to Fa", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Fahad"])
        XCTAssertEqual(speakers, [nil, nil], "a 2-char prefix is too short to trust — stays unattributed")
    }

    func test_attribute_noCandidates_alwaysUnattributed() {
        let texts = ["over to Fahad", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: [])
        XCTAssertEqual(speakers, [nil, nil])
    }

    // MARK: - Back-to-back handoffs

    func test_attribute_backToBackHandoffs_inConsecutiveSegments() {
        let texts = [
            "over to Fahad",  // 0: unattributed (previous speaker)
            "over to Alex",   // 1: Fahad (this line is the handoff INTO Alex, stays with Fahad)
            "thanks everyone",// 2: Alex
        ]
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: texts, candidates: ["Fahad", "Alex"])
        XCTAssertEqual(speakers, [nil, "Fahad", "Alex"])
    }

    func test_attribute_twoHandoffsInTheSameSegment_lastOneWins() {
        let texts = [
            "over to Fahad, actually back to you, Alex",
            "thanks",
        ]
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: texts, candidates: ["Fahad", "Alex"])
        XCTAssertEqual(speakers, [nil, "Alex"])
    }

    // MARK: - FINDING 1 (review): bare "over to" false-positives

    /// The reviewer's exact reproduction: a bare "over to" mid-sentence,
    /// pointing at something that is NOT the end of the clause, must never
    /// be treated as a handoff.
    func test_attribute_bareOverTo_midSentence_isNotAHandoff_reviewerRepro() {
        let texts = ["let's move over to Sam's slide for revenue", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Sam"])
        XCTAssertEqual(speakers, [nil, nil])
    }

    func test_detectHandoffs_bareOverTo_midSentence_producesNoHandoff_reviewerRepro() {
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(
            texts: ["let's move over to Sam's slide for revenue"]).isEmpty)
    }

    /// A second, unrelated bare "over to" that also isn't clause-ending.
    func test_attribute_bareOverTo_geographicPhrase_isNotAHandoff() {
        let texts = ["we went over to the office yesterday", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: texts, candidates: ["Office", "Offices"])
        XCTAssertEqual(speakers, [nil, nil])
    }

    /// A genuine bare "over to" that DOES end the clause must still fire —
    /// the tightening is about trailing content, not about the phrase
    /// itself.
    func test_detectHandoffs_bareOverTo_stillFiresAtClauseEnd() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(texts: ["Over to Alin."])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Alin")])
    }

    func test_attribute_bareOverTo_stillFiresAtClauseEnd() {
        let texts = ["Over to Alin.", "thanks"]
        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: ["Alin"])
        XCTAssertEqual(speakers, [nil, "Alin"])
    }

    /// The clause-end tightening applies ONLY to the bare "over to"
    /// pattern — the other four families are unaffected and still fire
    /// with trailing content after the name.
    func test_detectHandoffs_passItBackTo_isNotRestrictedByClauseEnd() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(
            texts: ["I shall pass it back to Alex, thanks everyone"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Alex")])
    }

    func test_detectHandoffs_handOverTo_isNotRestrictedByClauseEnd() {
        let handoffs = MeetingSpeakerAttribution.detectHandoffs(
            texts: ["I'll hand over to Devi, and she'll take it from here"])
        XCTAssertEqual(handoffs, [Handoff(segmentIndex: 0, name: "Devi")])
    }

    // MARK: - FINDING 1a (review): possessive names are never a handoff name

    func test_detectHandoffs_possessiveName_isNeverAHandoff() {
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(texts: ["over to Sam's."]).isEmpty)
    }

    func test_detectHandoffs_possessiveName_isNeverAHandoff_evenWithoutTrailingPunctuation() {
        // Isolate rule (a) from rule (b): this text ends right after the
        // possessive token (no trailing content at all), so a clause-end
        // check alone would let it through — only the possessive check
        // rejects it.
        XCTAssertTrue(MeetingSpeakerAttribution.detectHandoffs(texts: ["over to Sam's"]).isEmpty)
    }

    // MARK: - FINDING 2 (review): ambiguous candidate match stays unattributed

    /// The reviewer's exact reproduction: "Ali" fuzzy-matches both "Alina"
    /// and "Alison" — an ambiguous match must never silently pick the
    /// first candidate in list order.
    func test_attribute_ambiguousCandidateMatch_staysUnattributed_reviewerRepro() {
        let texts = ["over to Ali", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: texts, candidates: ["Alina", "Alison"])
        XCTAssertEqual(speakers, [nil, nil])
    }

    func test_attribute_uniqueFuzzyMatch_stillResolves() {
        let texts = ["over to Ali", "next update"]
        let speakers = MeetingSpeakerAttribution.attribute(
            texts: texts, candidates: ["Alina", "Bob"])
        XCTAssertEqual(speakers, [nil, "Alina"], "only one candidate matches — no ambiguity")
    }

    // MARK: - Realism: a standup handoff chain

    func test_realisticStandupChain_attributesEachSpanCorrectly() {
        let texts = [
            "Alright everyone let's get started with standup",       // 0: unattributed (host)
            "I finished the login flow and I'm starting on the API", // 1: unattributed (host)
            "over to Fahad",                                          // 2: unattributed (handoff line)
            "Thanks. I shipped the release yesterday",                // 3: Fahad
            "and today I'm picking up the bug fixes",                 // 4: Fahad
            "I shall pass it back to Alex",                           // 5: Fahad (handoff line)
            "Cheers. I'm blocked on the design review",               // 6: Alex
            "over to Liam",                                           // 7: Alex (handoff line, unknown name)
            "no updates from me today",                               // 8: unattributed — Liam isn't a candidate
            "back to you, Jerry",                                     // 9: unattributed (handoff line)
            "Thanks, that's everything for today",                    // 10: Jerry
        ]
        let candidates = ["Fahad", "Alex", "Jerry"]

        let speakers = MeetingSpeakerAttribution.attribute(texts: texts, candidates: candidates)

        XCTAssertEqual(speakers, [
            nil, nil,
            nil, "Fahad", "Fahad", "Fahad",
            "Alex", "Alex", nil, nil,
            "Jerry",
        ])
    }
}
