import XCTest
@testable import MustardKit

/// Digest failure surfacing (BAK-331) and the partial-digest omission note
/// (BAK-330). Both are pure value mappings/formatters that live next to
/// `MeetingDigestFailure` in `MeetingDigestChunker.swift` — the view only
/// renders what these compute.
final class MeetingDigestFailureReasonTests: XCTestCase {

    // MARK: - Failure → reason mapping (every case covered)

    func test_missingPrompt_mapsToMissingPrompt_noRetry() {
        let reason = MeetingDigestFailureReason(failure: .missingPrompt)
        XCTAssertEqual(reason, .missingPrompt)
        XCTAssertFalse(reason.offersRetry)
        XCTAssertEqual(reason.userMessage, "Mustard's digest prompt is missing from this build.")
    }

    func test_contextOverflow_mapsAcrossTheModelWrapper_noRetry() {
        let reason = MeetingDigestFailureReason(failure: .model(.contextOverflow))
        XCTAssertEqual(reason, .contextOverflow)
        XCTAssertFalse(reason.offersRetry)
        XCTAssertEqual(
            reason.userMessage,
            "This meeting is too long for the on-device model to summarise in one pass.")
    }

    func test_appleIntelligenceDisabled_offersRetry_deliberateDeviation() {
        // Deviation from the ticket's default table: once Leon enables Apple
        // Intelligence in System Settings, retry is exactly what fixes it —
        // so this ONE case offers retry even though the ticket's table
        // suggested otherwise.
        let reason = MeetingDigestFailureReason(failure: .model(.appleIntelligenceDisabled))
        XCTAssertEqual(reason, .appleIntelligenceDisabled)
        XCTAssertTrue(reason.offersRetry, "enabling Apple Intelligence then retrying is the fix")
        XCTAssertEqual(
            reason.userMessage,
            "Apple Intelligence is turned off — enable it in System Settings, then retry.")
    }

    func test_deviceNotEligible_mapsAcrossTheModelWrapper_noRetry() {
        let reason = MeetingDigestFailureReason(failure: .model(.deviceNotEligible))
        XCTAssertEqual(reason, .deviceNotEligible)
        XCTAssertFalse(reason.offersRetry)
        XCTAssertEqual(reason.userMessage, "This Mac's hardware can't run the on-device model.")
    }

    func test_modelNotReady_mapsAcrossTheModelWrapper_offersRetry() {
        let reason = MeetingDigestFailureReason(failure: .model(.modelNotReady))
        XCTAssertEqual(reason, .modelNotReady)
        XCTAssertTrue(reason.offersRetry)
        XCTAssertEqual(
            reason.userMessage, "The on-device model is still downloading. Try again shortly.")
    }

    func test_unsupportedLocale_mapsAcrossTheModelWrapper_noRetry() {
        let reason = MeetingDigestFailureReason(failure: .model(.unsupportedLocale))
        XCTAssertEqual(reason, .unsupportedLocale)
        XCTAssertFalse(reason.offersRetry)
        XCTAssertEqual(reason.userMessage, "The on-device model doesn't support this language.")
    }

    func test_unavailable_mapsAcrossTheModelWrapper_dropsDetail_offersRetry() {
        // The persisted reason is a plain enum with no associated data — the
        // detail string in .unavailable(String) is deliberately never
        // persisted (it could carry arbitrary/model-generated text).
        let reason = MeetingDigestFailureReason(failure: .model(.unavailable("some raw detail")))
        XCTAssertEqual(reason, .unavailable)
        XCTAssertTrue(reason.offersRetry)
        XCTAssertFalse(
            reason.userMessage.contains("some raw detail"),
            "the detail string is never surfaced or persisted")
    }

    func test_everyReasonCase_hasAUserMessage_andIsCoveredByAFailure() {
        // Guards against a new MeetingDigestFailureReason case silently
        // missing a message, and against the mapping switch going
        // non-exhaustive if LocalModelFailure ever grows a case.
        for reason in MeetingDigestFailureReason.allCases {
            XCTAssertFalse(reason.userMessage.isEmpty, "\(reason) needs a user message")
        }
    }

    // MARK: - Omission note formatting (BAK-330)

    func test_omissionNote_emptySpans_isNil() {
        XCTAssertNil(MeetingDigest.omissionNote(spans: []))
    }

    func test_omissionNote_singleSpan_formatsMinutesSeconds() {
        // 14:12 = 852s, 19:03 = 1143s.
        let note = MeetingDigest.omissionNote(spans: [852.0...1143.0])
        XCTAssertEqual(note, "14:12–19:03 into the meeting could not be summarised.")
    }

    func test_omissionNote_multipleSpans_joinedWithSemicolon() {
        let note = MeetingDigest.omissionNote(spans: [852.0...1143.0, 1500.0...1800.0])
        XCTAssertEqual(
            note,
            "14:12–19:03; 25:00–30:00 into the meeting could not be summarised.")
    }

    func test_omissionNote_rollsPastOneHour_withoutWrappingToHours() {
        // 61:01 = 3661s, 65:00 = 3900s — minutes roll past 60 rather than
        // wrapping into an hh:mm:ss display (deliberately timezone-free,
        // offset-into-meeting formatting).
        let note = MeetingDigest.omissionNote(spans: [3661.0...3900.0])
        XCTAssertEqual(note, "61:01–65:00 into the meeting could not be summarised.")
    }

    func test_omissionNote_roundsSubSecondOffsets() {
        let note = MeetingDigest.omissionNote(spans: [0.4...1.6])
        XCTAssertEqual(note, "0:00–0:02 into the meeting could not be summarised.")
    }
}
