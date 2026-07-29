import XCTest
@testable import MustardKit

/// Pure capture outcome + transcript normalization (F25 v1, ADR-0011).
final class VoiceCaptureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func release(after seconds: TimeInterval, transcript: String) -> VoiceCapture.Outcome {
        VoiceCapture.outcome(pressedAt: t0, releasedAt: t0.addingTimeInterval(seconds), transcript: transcript)
    }

    // MARK: - Outcome

    func test_commit_normalHoldWithSpeech() {
        XCTAssertEqual(release(after: 2.0, transcript: "buy milk"), .commit(title: "Buy milk"))
    }

    func test_cancel_holdShorterThanMinimum() {
        XCTAssertEqual(release(after: 0.1, transcript: "buy milk"), .cancelled(.tooShort))
    }

    func test_holdExactlyAtMinimum_commits() {
        XCTAssertEqual(release(after: VoiceCapture.minimumHold, transcript: "x"),
                       .commit(title: "X"))
    }

    func test_cancel_emptyTranscript() {
        XCTAssertEqual(release(after: 2.0, transcript: ""), .cancelled(.emptyTranscript))
    }

    func test_cancel_whitespaceOnlyTranscript() {
        XCTAssertEqual(release(after: 2.0, transcript: "  \n \t "), .cancelled(.emptyTranscript))
    }

    func test_cancel_negativeElapsed_neverCommits() {
        // A clock hiccup (release timestamp before press) must not commit.
        XCTAssertEqual(release(after: -1.0, transcript: "buy milk"), .cancelled(.tooShort))
    }

    func test_tooShortWins_overEmptyTranscript() {
        // An accidental tap cancels as a tap, whatever the recognizer produced.
        XCTAssertEqual(release(after: 0.05, transcript: ""), .cancelled(.tooShort))
    }

    // MARK: - Title normalization

    func test_normalize_trimsAndCapitalizesFirstLetter() {
        XCTAssertEqual(VoiceCapture.normalizeTitle("  release the prep app  "),
                       "Release the prep app")
    }

    func test_normalize_collapsesInternalWhitespaceAndNewlines() {
        XCTAssertEqual(VoiceCapture.normalizeTitle("check  the\ndesign\n\nmeeting"),
                       "Check the design meeting")
    }

    func test_normalize_dropsTrailingFullStop_keepsOtherPunctuation() {
        // SFSpeech's addsPunctuation ends most utterances with "." — noise in a title.
        XCTAssertEqual(VoiceCapture.normalizeTitle("buy milk."), "Buy milk")
        XCTAssertEqual(VoiceCapture.normalizeTitle("is this due Friday?"), "Is this due Friday?")
        XCTAssertEqual(VoiceCapture.normalizeTitle("ship it!"), "Ship it!")
    }

    func test_normalize_preservesEllipsis() {
        XCTAssertEqual(VoiceCapture.normalizeTitle("wait..."), "Wait...")
    }

    func test_normalize_preservesInteriorSentencePunctuation() {
        XCTAssertEqual(
            VoiceCapture.normalizeTitle("check the meeting. email Matt the actions."),
            "Check the meeting. email Matt the actions")
    }

    func test_normalize_alreadyCapitalized_unchanged() {
        XCTAssertEqual(VoiceCapture.normalizeTitle("Email Kamil"), "Email Kamil")
    }

    func test_normalize_singleCharacter() {
        XCTAssertEqual(VoiceCapture.normalizeTitle("x"), "X")
    }

    func test_normalize_emptyStaysEmpty() {
        XCTAssertEqual(VoiceCapture.normalizeTitle(""), "")
        XCTAssertEqual(VoiceCapture.normalizeTitle(" . "), "")
    }

    func test_commit_usesNormalizedTitle() {
        XCTAssertEqual(release(after: 1.0, transcript: "  email   Matt the action points. "),
                       .commit(title: "Email Matt the action points"))
    }

    // MARK: - Segment → text (modern engine, Capture Task 3)

    private func seg(_ id: String, _ text: String, start: Double, final: Bool) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: start + 1,
            isFinal: final, confidence: nil, source: .microphone)
    }

    func test_transcript_joinsFinalSegmentsInStartOrder_excludingProvisionals() {
        let segments = [
            seg("b", "and eggs", start: 2, final: true),
            seg("a", "buy milk", start: 0, final: true),
            seg("c", "maybe bre", start: 4, final: false),
        ]
        XCTAssertEqual(VoiceCapture.transcript(from: segments), "buy milk and eggs")
    }

    func test_transcript_emptyWhenOnlyProvisionals() {
        XCTAssertEqual(VoiceCapture.transcript(from: [seg("a", "buy mi", start: 0, final: false)]), "")
    }

    func test_liveTranscript_includesProvisionalsInStartOrder() {
        let segments = [
            seg("b", "and eg", start: 2, final: false),
            seg("a", "buy milk", start: 0, final: true),
        ]
        XCTAssertEqual(VoiceCapture.liveTranscript(segments), "buy milk and eg")
    }
}

/// The `MustardTask` capture columns round-trip through their raw storage (ADR-0011:
/// additive, CloudKit-safe — optional or defaulted).
final class VoiceCaptureModelTests: XCTestCase {
    func test_captureState_accessorRoundTrips() {
        let task = MustardTask(title: "Raw words")
        XCTAssertNil(task.captureState)          // ordinary tasks carry no capture state
        task.captureState = .raw
        XCTAssertEqual(task.captureStateRaw, "raw")
        XCTAssertEqual(task.captureState, .raw)
        task.captureState = .cleaned
        XCTAssertEqual(task.captureState, .cleaned)
        task.captureState = nil
        XCTAssertNil(task.captureStateRaw)
    }

    func test_captureDefaults_areAdditive() {
        let task = MustardTask(title: "t")
        XCTAssertNil(task.captureTranscript)
        XCTAssertEqual(task.captureAttempts, 0)
        XCTAssertNil(task.captureNextAttemptAt)
    }
}
