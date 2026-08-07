import XCTest
@testable import MustardKit

/// Framework-independent voice contracts (Voice Core Task 2): transcript
/// segments, audio sources, and readiness states. These are the value types
/// every voice feature exchanges, so their shape (finality, timing order,
/// optional confidence, readiness equality) is pinned here.
final class VoiceTypesTests: XCTestCase {

    // MARK: - Segment mapping (stable vs provisional)

    func testStableSegmentKeepsSourceAndTiming() {
        let segment = VoiceTranscriptSegment(
            id: "s1", text: "Send the notes", startSeconds: 1.2,
            endSeconds: 2.8, isFinal: true, confidence: 0.91, source: .microphone)
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(segment.source, .microphone)
        XCTAssertEqual(segment.startSeconds, 1.2)
        XCTAssertEqual(segment.endSeconds, 2.8)
        XCTAssertEqual(segment.text, "Send the notes")
        XCTAssertEqual(segment.id, "s1")
        XCTAssertEqual(segment.confidence, 0.91)
    }

    func testProvisionalSegmentIsNotFinal() {
        let segment = VoiceTranscriptSegment(
            id: "p1", text: "Send the", startSeconds: 1.2,
            endSeconds: 2.1, isFinal: false, confidence: nil, source: .microphone)
        XCTAssertFalse(segment.isFinal)
    }

    func testProvisionalAndStableSegmentsWithSameContentDifferOnlyByFinality() {
        let provisional = VoiceTranscriptSegment(
            id: "s1", text: "Send the notes", startSeconds: 1.2,
            endSeconds: 2.8, isFinal: false, confidence: 0.91, source: .microphone)
        let stable = VoiceTranscriptSegment(
            id: "s1", text: "Send the notes", startSeconds: 1.2,
            endSeconds: 2.8, isFinal: true, confidence: 0.91, source: .microphone)
        XCTAssertNotEqual(provisional, stable)
    }

    // MARK: - Ordered timestamps

    func testSegmentsPreserveTimestampOrderingAcrossAStream() {
        let first = VoiceTranscriptSegment(
            id: "s1", text: "Send", startSeconds: 0.0,
            endSeconds: 0.9, isFinal: true, confidence: 0.8, source: .meeting)
        let second = VoiceTranscriptSegment(
            id: "s2", text: "the notes", startSeconds: 0.9,
            endSeconds: 2.4, isFinal: true, confidence: 0.85, source: .meeting)
        XCTAssertLessThanOrEqual(first.startSeconds, first.endSeconds)
        XCTAssertLessThanOrEqual(second.startSeconds, second.endSeconds)
        XCTAssertLessThanOrEqual(first.endSeconds, second.startSeconds)
    }

    // MARK: - Optional confidence

    func testConfidenceIsOptionalAndAbsenceIsDistinctFromZero() {
        let unscored = VoiceTranscriptSegment(
            id: "s1", text: "hello", startSeconds: 0, endSeconds: 1,
            isFinal: true, confidence: nil, source: .microphone)
        let zero = VoiceTranscriptSegment(
            id: "s1", text: "hello", startSeconds: 0, endSeconds: 1,
            isFinal: true, confidence: 0.0, source: .microphone)
        XCTAssertNil(unscored.confidence)
        XCTAssertNotEqual(unscored, zero)
    }

    // MARK: - Audio source

    func testAudioSourceRawValuesAreStableForPersistence() {
        XCTAssertEqual(VoiceAudioSource.microphone.rawValue, "microphone")
        XCTAssertEqual(VoiceAudioSource.meeting.rawValue, "meeting")
    }

    func testAudioSourceCodableRoundTrip() throws {
        let sources: [VoiceAudioSource] = [.microphone, .meeting]
        let data = try JSONEncoder().encode(sources)
        let decoded = try JSONDecoder().decode([VoiceAudioSource].self, from: data)
        XCTAssertEqual(decoded, sources)
    }

    // MARK: - Readiness states

    func testSupportedReadinessStatesAreEquatable() {
        XCTAssertEqual(VoiceReadiness.ready, .ready)
        XCTAssertEqual(VoiceReadiness.needsAssetDownload, .needsAssetDownload)
        XCTAssertEqual(VoiceReadiness.permissionDenied, .permissionDenied)
        XCTAssertEqual(VoiceReadiness.unsupportedLocale, .unsupportedLocale)
        XCTAssertNotEqual(VoiceReadiness.ready, .needsAssetDownload)
    }

    func testUnavailableCarriesItsReason() {
        XCTAssertEqual(VoiceReadiness.unavailable("model missing"),
                       .unavailable("model missing"))
        XCTAssertNotEqual(VoiceReadiness.unavailable("model missing"),
                          .unavailable("asset install failed"))
        XCTAssertNotEqual(VoiceReadiness.unavailable("model missing"), .ready)
    }
}
