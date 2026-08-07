import XCTest
@testable import MustardKit

/// Transcript chunking for digest generation (Meetings Task 7, BAK-299):
/// deterministic, budget-driven, silence-preferring. Token counting is
/// injected — here 1 token per character keeps arithmetic obvious.
final class MeetingDigestChunkerTests: XCTestCase {

    private func seg(
        _ id: String, _ text: String, start: Double, end: Double
    ) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: end,
            isFinal: true, confidence: nil, source: .microphone)
    }

    private func chunks(
        _ segments: [VoiceTranscriptSegment], budget: Int
    ) -> [[VoiceTranscriptSegment]] {
        MeetingDigestChunker.chunks(
            segments: segments, budgetTokens: budget, tokenCount: { $0.count })
    }

    func test_everythingFits_isOneChunk() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("b", "12345", start: 1, end: 2),
        ]
        XCTAssertEqual(chunks(segments, budget: 20).map { $0.map(\.id) }, [["a", "b"]])
    }

    func test_budgetOverflow_prefersTheSilenceBoundary() {
        // a—b are continuous; a ≥2s gap separates b and c; overflow happens at
        // d, and the cut goes back to the silence boundary after b.
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("b", "12345", start: 1, end: 2),
            seg("c", "12345", start: 5, end: 6),   // 3s of silence before this
            seg("d", "12345", start: 6, end: 7),
        ]
        XCTAssertEqual(
            chunks(segments, budget: 16).map { $0.map(\.id) },
            [["a", "b"], ["c", "d"]],
            "the cut lands on silence, not mid-speech")
    }

    func test_budgetOverflow_withoutSilence_cutsAtThePreviousSegment() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("b", "12345", start: 1, end: 2),
            seg("c", "12345", start: 2, end: 3),
        ]
        XCTAssertEqual(
            chunks(segments, budget: 12).map { $0.map(\.id) },
            [["a", "b"], ["c"]])
    }

    func test_oversizedSingleSegment_getsItsOwnChunk() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("huge", String(repeating: "x", count: 100), start: 1, end: 9),
            seg("b", "12345", start: 9, end: 10),
        ]
        XCTAssertEqual(
            chunks(segments, budget: 20).map { $0.map(\.id) },
            [["a"], ["huge"], ["b"]],
            "an oversized segment is never dropped and never loops")
    }

    func test_chunking_isDeterministic() {
        let segments = (0..<20).map { i in
            seg("s\(i)", "1234567890", start: Double(i), end: Double(i) + 0.5)
        }
        XCTAssertEqual(
            chunks(segments, budget: 35).map { $0.map(\.id) },
            chunks(segments, budget: 35).map { $0.map(\.id) })
    }

    func test_emptyTranscript_hasNoChunks() {
        XCTAssertTrue(chunks([], budget: 100).isEmpty)
    }
}
