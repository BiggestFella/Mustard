import XCTest
@testable import MustardKit

/// Adjacent same-source segment merging ahead of digest generation
/// (BAK-329): near-word-level finals from the live transcriber (~15 chars
/// each) cost a ~44-char id/timing prefix per line in the digest prompt, so
/// merging on a pause rule turns hundreds of segments into a handful of
/// utterances without touching the persisted transcript.
final class MeetingUtteranceMergeTests: XCTestCase {

    // MARK: - Fixtures

    private func seg(
        _ id: String, _ text: String,
        start: Double, end: Double,
        source: VoiceAudioSource = .microphone,
        confidence: Double? = nil,
        speaker: String? = nil
    ) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: end,
            isFinal: true, confidence: confidence, source: source, speaker: speaker)
    }

    // MARK: - Pause rule

    func test_pauseBelowThreshold_sameSource_merges() {
        let segments = [
            seg("a", "so my plan", start: 0.0, end: 1.0),
            seg("b", "is to ship", start: 1.4, end: 2.0), // 0.4s gap < 1.5s
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances[0].segments.map(\.id), ["a", "b"])
    }

    func test_pauseAtOrAboveThreshold_sameSource_splits() {
        let segments = [
            seg("a", "so my plan", start: 0.0, end: 1.0),
            seg("b", "is to ship", start: 2.5, end: 3.0), // 1.5s gap == threshold
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances.map { $0.segments.map(\.id) }, [["a"], ["b"]])
    }

    // MARK: - Source interleaving

    func test_otherSourceSegmentBetween_breaksTheRun_orderPreserved() {
        let segments = [
            seg("a1", "hello", start: 0.0, end: 1.0, source: .microphone),
            seg("m1", "hi there", start: 1.1, end: 2.0, source: .meeting),
            seg("a2", "how's it going", start: 2.1, end: 3.0, source: .microphone),
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(
            utterances.map { $0.segments.map(\.id) },
            [["a1"], ["m1"], ["a2"]],
            "a different-source segment always breaks the run, and order is never reshuffled")
        XCTAssertEqual(utterances.map(\.source), [.microphone, .meeting, .microphone])
    }

    // MARK: - Text joining

    func test_text_trimsAndJoinsWithSingleSpace() {
        let segments = [
            seg("a", "  hello  ", start: 0.0, end: 1.0),
            seg("b", "world  ", start: 1.1, end: 2.0),
        ]

        let utterance = MeetingUtteranceMerge.utterances(from: segments)[0]

        XCTAssertEqual(utterance.text, "hello world")
    }

    func test_text_skipsEmptyConstituentTexts() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0),
            seg("b", "   ", start: 1.1, end: 2.0),
            seg("c", "world", start: 2.1, end: 3.0),
        ]

        let utterance = MeetingUtteranceMerge.utterances(from: segments)[0]

        XCTAssertEqual(utterance.text, "hello world")
    }

    // MARK: - maxTextLength

    func test_maxTextLength_splitsRatherThanExceeding() {
        let long = String(repeating: "x", count: 60)
        // 40 segments * 60 chars = 2400 raw chars, well past a 100-char cap.
        let segments = (0..<40).map { i in
            seg("s\(i)", long, start: Double(i), end: Double(i) + 0.5)
        }

        let utterances = MeetingUtteranceMerge.utterances(
            from: segments, maxTextLength: 100)

        XCTAssertGreaterThan(utterances.count, 1, "a 2400-char run must split under a 100-char cap")
        for utterance in utterances {
            XCTAssertLessThanOrEqual(utterance.text.count, 100)
        }
    }

    // MARK: - segmentIDs

    func test_segmentIDs_arePersistentIDsOfEveryConstituent_inOrder() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting),
        ]

        let utterance = MeetingUtteranceMerge.utterances(from: segments)[0]

        XCTAssertEqual(utterance.segmentIDs, ["meeting:a", "meeting:b"])
    }

    // MARK: - asSegment

    func test_asSegment_idIsFirstConstituentRawID_spanCoversFirstStartToLastEnd() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0),
            seg("b", "world", start: 1.1, end: 2.5),
        ]

        let asSegment = MeetingUtteranceMerge.utterances(from: segments)[0].asSegment

        XCTAssertEqual(asSegment.id, "a", "the RAW id, not the persistent id — the caller namespaces it")
        XCTAssertEqual(asSegment.startSeconds, 0.0)
        XCTAssertEqual(asSegment.endSeconds, 2.5)
        XCTAssertEqual(asSegment.text, "hello world")
        XCTAssertTrue(asSegment.isFinal)
        XCTAssertEqual(asSegment.source, .microphone)
    }

    func test_asSegment_confidenceIsTheMeanOfConstituents() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, confidence: 0.6),
            seg("b", "world", start: 1.1, end: 2.0, confidence: 0.8),
        ]

        let asSegment = MeetingUtteranceMerge.utterances(from: segments)[0].asSegment

        XCTAssertEqual(asSegment.confidence ?? -1, 0.7, accuracy: 0.0001)
    }

    // MARK: - Speaker boundary (BAK-335)

    func test_speakerChange_breaksTheRun_evenWithinPauseThreshold() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: "Fahad"),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting, speaker: "Alex"),
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(
            utterances.map { $0.segments.map(\.id) }, [["a"], ["b"]],
            "a speaker change always breaks the run, just like a source change")
    }

    func test_speakerChange_nilToNamed_breaksTheRun() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: nil),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting, speaker: "Alex"),
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(utterances.map { $0.segments.map(\.id) }, [["a"], ["b"]])
    }

    func test_sameSpeaker_doesNotBreakTheRun() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: "Fahad"),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting, speaker: "Fahad"),
        ]

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(utterances.count, 1, "same speaker, same source, within pause — one utterance")
    }

    func test_utterance_speakerIsFirstConstituents() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: "Fahad"),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting, speaker: "Fahad"),
        ]

        let utterance = MeetingUtteranceMerge.utterances(from: segments)[0]

        XCTAssertEqual(utterance.speaker, "Fahad")
    }

    func test_utterance_speakerIsNilWhenUnattributed() {
        let segments = [seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: nil)]

        let utterance = MeetingUtteranceMerge.utterances(from: segments)[0]

        XCTAssertNil(utterance.speaker)
    }

    func test_asSegment_carriesTheUtterancesSpeaker() {
        let segments = [
            seg("a", "hello", start: 0.0, end: 1.0, source: .meeting, speaker: "Fahad"),
            seg("b", "world", start: 1.1, end: 2.0, source: .meeting, speaker: "Fahad"),
        ]

        let asSegment = MeetingUtteranceMerge.utterances(from: segments)[0].asSegment

        XCTAssertEqual(asSegment.speaker, "Fahad")
    }

    // MARK: - Empty input

    func test_emptyInput_producesNoUtterances() {
        XCTAssertTrue(MeetingUtteranceMerge.utterances(from: []).isEmpty)
    }

    // MARK: - Realism (BAK-329: the actual standup shape)

    /// ~1,100 near-word-level segments alternating a plausible speaker
    /// pattern (bursts of continuous same-source speech, occasional
    /// cross-talk, natural pauses) — the merge must collapse this down
    /// dramatically, and no utterance may exceed the cap on its own.
    func test_realisticTranscript_collapsesDramatically() {
        var segments: [VoiceTranscriptSegment] = []
        var t = 0.0
        var id = 0
        // 220 bursts of ~5 words each, alternating source every few bursts,
        // with an occasional longer pause between bursts.
        for burst in 0..<220 {
            let source: VoiceAudioSource = (burst / 4) % 2 == 0 ? .microphone : .meeting
            for _ in 0..<5 {
                segments.append(seg("s\(id)", "word here now", start: t, end: t + 0.3, source: source))
                id += 1
                t += 0.35 // within-burst gap, well under threshold
            }
            t += (burst % 7 == 0) ? 2.0 : 0.9 // occasional real pause between bursts
        }

        let utterances = MeetingUtteranceMerge.utterances(from: segments)

        XCTAssertEqual(segments.count, 1_100)
        XCTAssertLessThan(
            Double(utterances.count), Double(segments.count) * 0.25,
            "merging must collapse the transcript to well under a quarter of the segment count")
        for utterance in utterances {
            XCTAssertLessThanOrEqual(utterance.text.count, MeetingUtteranceMerge.maxTextLength)
        }
    }
}
