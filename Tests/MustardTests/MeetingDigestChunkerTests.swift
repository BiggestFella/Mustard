import XCTest
@testable import MustardKit

/// Transcript chunking for digest generation (Meetings Task 7, BAK-299):
/// deterministic, budget-driven, silence-preferring. Token counting is
/// injected — here 1 token per character keeps arithmetic obvious.
///
/// BAK-328: costs are charged against the RENDERED prompt line
/// (`MeetingDigestChunker.renderedLine`), not the raw segment text — the
/// ~44-char id/timing prefix `chunkPrompt` adds is real prompt weight that a
/// raw-text budget silently ignored, overflowing the on-device model's
/// context past ~5 minutes of speech.
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

    /// The real per-segment cost once rendering is accounted for — used to
    /// derive budgets that exercise a specific cut point without hardcoding
    /// fragile character counts that would drift if the prompt format ever
    /// changes width.
    private func cost(_ segment: VoiceTranscriptSegment) -> Int {
        MeetingDigestChunker.renderedLine(for: segment).count
    }

    func test_everythingFits_isOneChunk() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("b", "12345", start: 1, end: 2),
        ]
        let budget = cost(segments[0]) + cost(segments[1])
        XCTAssertEqual(chunks(segments, budget: budget).map { $0.map(\.id) }, [["a", "b"]])
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
        // Covers a+b+c but not a+b+c+d.
        let budget = cost(segments[0]) + cost(segments[1]) + cost(segments[2])
        XCTAssertEqual(
            chunks(segments, budget: budget).map { $0.map(\.id) },
            [["a", "b"], ["c", "d"]],
            "the cut lands on silence, not mid-speech")
    }

    func test_budgetOverflow_withoutSilence_cutsAtThePreviousSegment() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("b", "12345", start: 1, end: 2),
            seg("c", "12345", start: 2, end: 3),
        ]
        // Covers a+b but not a+b+c, and there is no silence boundary.
        let budget = cost(segments[0]) + cost(segments[1])
        XCTAssertEqual(
            chunks(segments, budget: budget).map { $0.map(\.id) },
            [["a", "b"], ["c"]])
    }

    func test_oversizedSingleSegment_getsItsOwnChunk() {
        let segments = [
            seg("a", "12345", start: 0, end: 1),
            seg("huge", String(repeating: "x", count: 100), start: 1, end: 9),
            seg("b", "12345", start: 9, end: 10),
        ]
        // Enough for "a" alone, nowhere near enough for "huge"'s rendered line.
        let budget = cost(segments[0])
        XCTAssertEqual(
            chunks(segments, budget: budget).map { $0.map(\.id) },
            [["a"], ["huge"], ["b"]],
            "an oversized segment is never dropped and never loops")
    }

    // MARK: - Rendered-cost accounting (BAK-328)

    func test_chunkCost_isTheRenderedPromptLine_notTheRawText() {
        // ~1,100 short segments (~15 chars of text, realistic ids) — enough
        // real-world weight that a raw-text budget would pack ~500+ segments
        // per chunk, while the rendered prompt (id/channel/timing prefix
        // included) is ~4x heavier per line.
        let segments = (0..<1_100).map { i in
            seg("seg-\(i)", "short text here", start: Double(i) * 2, end: Double(i) * 2 + 1)
        }
        let budget = 2048
        let result = MeetingDigestChunker.chunks(
            segments: segments, budgetTokens: budget,
            tokenCount: { $0.count / 4 + 1 })

        XCTAssertFalse(result.isEmpty)
        for chunk in result {
            let rendered = chunk.map(MeetingDigestChunker.renderedLine(for:)).joined(separator: "\n")
            let renderedCost = rendered.count / 4 + 1
            XCTAssertLessThanOrEqual(
                renderedCost, budget,
                "a chunk's RENDERED prompt must fit the budget — packing by raw-text cost "
                    + "alone lets the real prompt overflow the model's context")
        }
    }

    func test_renderedLine_matchesThePromptFormat() {
        let segment = VoiceTranscriptSegment(
            id: "seg-3", text: "let's ship Friday", startSeconds: 12.34, endSeconds: 14.5,
            isFinal: true, confidence: nil, source: .meeting)

        XCTAssertEqual(
            MeetingDigestChunker.renderedLine(for: segment),
            "[meeting:seg-3] (meeting 12.3–14.5s): let's ship Friday")
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
