import XCTest
@testable import MustardKit

/// BAK-332: after a real incident where the mic writer silently never wrote
/// a file while the mic kept transcribing successfully (413 "you" segments,
/// zero mic bytes on disk, meeting still reported `ready`/`audioFinalized`),
/// this pure unit decides whether a finalized meeting's audio matches what
/// its transcript proves happened. A source only counts as lost when there is
/// POSITIVE evidence it was active (transcript segments exist for its
/// channel) yet no audio ever finalized for it — never for a source that
/// simply never started, and never for a source that legitimately captured
/// no speech.
final class MeetingSourceParityTests: XCTestCase {

    func test_allGood_bothSourcesTranscribedAndFinalized_isClean() {
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [.you, .meeting],
            finalizedChannels: [.you, .meeting])

        XCTAssertTrue(verdict.isClean)
        XCTAssertEqual(verdict.missing, [])
        XCTAssertNil(verdict.userMessage)
    }

    func test_missingYouAudio_transcribedButNeverFinalized_isFlaggedAsMicrophone() {
        // Mirrors the incident exactly: 413 "you" segments persisted, but
        // you.m4a never finalized.
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [.you, .meeting],
            finalizedChannels: [.meeting])

        XCTAssertFalse(verdict.isClean)
        XCTAssertEqual(verdict.missing, [.microphone])
        XCTAssertEqual(
            verdict.userMessage,
            "Microphone audio was not saved — the transcript is unaffected.")
    }

    func test_missingMeetingAudio_transcribedButNeverFinalized_isFlaggedAsSystemAudio() {
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [.you, .meeting],
            finalizedChannels: [.you])

        XCTAssertFalse(verdict.isClean)
        XCTAssertEqual(verdict.missing, [.systemAudio])
        XCTAssertEqual(
            verdict.userMessage,
            "System Audio audio was not saved — the transcript is unaffected.")
    }

    func test_sourceThatNeverStarted_isNeverFlagged_evenIfAbsentEverywhere() {
        // Only microphone was requested/started this meeting — systemAudio
        // was never promised, so its absence from both transcript and
        // finalized audio is not a mismatch.
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone],
            transcribedChannels: [.you],
            finalizedChannels: [.you])

        XCTAssertTrue(verdict.isClean)
    }

    func test_startedThenLost_transcribedNoFinalizedFile_isFlagged() {
        // Distinguishes "never started" (never flagged, above) from
        // "started, produced transcript evidence, then the writer lost it"
        // (flagged) — both sources requested, only one ever wrote a file.
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [.you, .meeting],
            finalizedChannels: [.meeting])

        XCTAssertEqual(verdict.missing, [.microphone])
    }

    func test_emptyTranscript_bothSourcesFinalized_isCleanRegardlessOfSilence() {
        // A short, quiet meeting: nobody spoke, but both tracks still
        // finalized (even if empty/near-empty) — no evidence of a mismatch.
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [],
            finalizedChannels: [.you, .meeting])

        XCTAssertTrue(verdict.isClean)
    }

    func test_emptyTranscript_audioAlsoMissing_isNotFlagged_noEvidenceEitherWay() {
        // No transcript AND no finalized audio for a started source is
        // ambiguous from pure evidence alone (could be total silence with no
        // writer failure at all — the writer only opens a file on first
        // append). Without transcript proof of activity, this unit does not
        // accuse the writer; it only flags a PROVEN mismatch.
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.microphone, .systemAudio],
            transcribedChannels: [],
            finalizedChannels: [])

        XCTAssertTrue(verdict.isClean)
    }

    func test_bothSourcesMissing_namesBothInDeterministicOrder() {
        let verdict = MeetingSourceParity.evaluate(
            startedSources: [.systemAudio, .microphone],
            transcribedChannels: [.you, .meeting],
            finalizedChannels: [])

        XCTAssertEqual(verdict.missing, [.microphone, .systemAudio])
        XCTAssertEqual(
            verdict.userMessage,
            "Microphone and System Audio audio was not saved — the transcript is unaffected.")
    }
}
