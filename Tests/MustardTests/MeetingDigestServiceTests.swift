import XCTest
@testable import MustardKit

/// Evidence-backed digest generation (Meetings Task 7, BAK-299): hierarchical
/// map/reduce over the injected generation seam, strict evidence validation
/// (no proposal survives without a real segment behind it), and typed
/// retryable failures. Pinned calendar; stub model.
final class MeetingDigestServiceTests: XCTestCase {

    // MARK: - Fixtures

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z")!
    }

    private func seg(
        _ id: String, _ text: String, start: Double = 0
    ) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: start + 1,
            isFinal: true, confidence: nil, source: .microphone)
    }

    /// Every segment's persistent id, as the prompts render them.
    private func pid(_ segment: VoiceTranscriptSegment) -> String {
        MeetingTranscriptMerge.persistentID(for: segment)
    }

    private final class StubRecorder: @unchecked Sendable {
        var prompts: [String] = []
        var instructions: [String] = []
    }

    private struct StubGenerating: OnDeviceGenerating {
        let recorder = StubRecorder()
        var capabilitiesResult: Result<LocalModelCapabilities, LocalModelFailure> =
            .success(LocalModelCapabilities(contextSize: 4096, promptBand: "27", osBuild: "27A5194q"))
        var results: [GeneratedMeetingDigest]
        /// 0-indexed generate() calls that should throw instead of returning
        /// a result — BAK-330's per-chunk failure tests.
        var failures: [Int: LocalModelFailure] = [:]
        private final class Cursor: @unchecked Sendable { var index = 0 }
        private let cursor = Cursor()

        init(results: [GeneratedMeetingDigest], failures: [Int: LocalModelFailure] = [:]) {
            self.results = results
            self.failures = failures
        }

        func capabilities(locale: Locale) async -> Result<LocalModelCapabilities, LocalModelFailure> {
            capabilitiesResult
        }

        func generate<Output>(
            _ type: Output.Type, instructions: String, prompt: String
        ) async throws -> Output {
            recorder.instructions.append(instructions)
            recorder.prompts.append(prompt)
            let index = cursor.index
            cursor.index += 1
            if let failure = failures[index] { throw failure }
            let result = results[min(index, results.count - 1)]
            return result as! Output
        }
    }

    private func generated(
        summary: String = "We planned the release.",
        decisions: [String] = ["Ship Friday"],
        questions: [String] = [],
        actions: [GeneratedMeetingAction] = []
    ) -> GeneratedMeetingDigest {
        GeneratedMeetingDigest(
            summary: summary, decisions: decisions,
            unresolvedQuestions: questions, actions: actions)
    }

    private func makeService(
        stub: StubGenerating,
        prompts: [String: String] = ["meeting-digest-27": "DIGEST-INSTRUCTIONS"],
        tokenCount: @escaping @Sendable (String) -> Int = { _ in 1 }
    ) -> MeetingDigestService {
        MeetingDigestService(
            service: stub,
            calendar: utc,
            locale: Locale(identifier: "en_AU"),
            promptBand: .macOS27,
            loadPrompt: { prompts[$0] },
            tokenCount: tokenCount)
    }

    // MARK: - Happy path

    func test_singleChunk_producesAValidatedStampedDigest() async throws {
        let segments = [seg("seg-1", "we should ship friday")]
        let action = GeneratedMeetingAction(
            title: "Ship the release",
            owner: "me",
            dueISO8601: "2026-07-31",
            evidenceSegmentIDs: [pid(segments[0])])
        let stub = StubGenerating(results: [generated(actions: [action])])

        let result = await makeService(stub: stub).digest(segments: segments, now: now)

        let digest = try result.get()
        XCTAssertEqual(digest.summary, "We planned the release.")
        XCTAssertEqual(digest.decisions, ["Ship Friday"])
        XCTAssertEqual(digest.actions.count, 1)
        XCTAssertEqual(digest.actions.first?.title, "Ship the release")
        XCTAssertEqual(
            digest.actions.first?.due,
            ISO8601DateFormatter().date(from: "2026-07-31T09:00:00Z"))
        XCTAssertEqual(digest.actions.first?.evidenceSegmentIDs, [pid(segments[0])])
        XCTAssertEqual(digest.promptVersion, PromptCatalog.promptVersion)
        XCTAssertEqual(digest.osBuild, "27A5194q")
        XCTAssertTrue(stub.recorder.prompts[0].contains(pid(segments[0])),
                      "the prompt renders segments under their persistent ids")
    }

    // MARK: - Evidence validation (never a proposal without real evidence)

    func test_actionsWithoutAnyRealEvidence_areDropped() async throws {
        let segments = [seg("seg-1", "we should ship friday")]
        let ghost = GeneratedMeetingAction(
            title: "Invented task", owner: nil, dueISO8601: nil,
            evidenceSegmentIDs: ["microphone:seg-999"])
        let mixed = GeneratedMeetingAction(
            title: "Real task", owner: nil, dueISO8601: nil,
            evidenceSegmentIDs: ["microphone:seg-999", pid(segments[0])])
        let stub = StubGenerating(results: [generated(actions: [ghost, mixed])])

        let digest = try await makeService(stub: stub)
            .digest(segments: segments, now: now).get()

        XCTAssertEqual(digest.actions.count, 1, "no evidence, no proposal")
        XCTAssertEqual(digest.actions.first?.title, "Real task")
        XCTAssertEqual(
            digest.actions.first?.evidenceSegmentIDs, [pid(segments[0])],
            "nonexistent ids are filtered out of surviving actions")
    }

    // MARK: - Hierarchical map/reduce

    func test_oversizedTranscript_mapsPerChunk_thenReduces() async throws {
        let segments = [
            seg("seg-1", "first half", start: 0),
            seg("seg-2", "second half", start: 10),
        ]
        let stub = StubGenerating(results: [
            generated(summary: "Part one."),
            generated(summary: "Part two."),
            generated(summary: "Everything combined."),
        ])
        // Each segment costs more than half the budget → two chunks + reduce.
        let service = makeService(stub: stub, tokenCount: { _ in 2000 })

        let digest = try await service.digest(segments: segments, now: now).get()

        XCTAssertEqual(stub.recorder.prompts.count, 3, "two map passes and one reduction")
        XCTAssertEqual(digest.summary, "Everything combined.")
        XCTAssertTrue(stub.recorder.prompts[2].contains("Part one."),
                      "the reduction sees the partial digests")
    }

    // MARK: - Budget (BAK-328: real instructions size + output reserve, not contextSize/2)

    func test_budget_isRealContextMinusInstructionsMinusOutputReserve() async throws {
        // Old formula: budget = contextSize/2 = 2048. New formula: budget =
        // contextSize - tokenCount(instructions) - outputReserve(1024). With
        // contextSize 4096 and the 19-char "DIGEST-INSTRUCTIONS" fixture,
        // the new budget is ~3053. Two segments whose combined RENDERED
        // cost sits strictly between 2048 and 3053 fit in ONE chunk under
        // the real budget, but would have been forced into two chunks (plus
        // a reduction pass) under the old contextSize/2 guess.
        let instructions = "DIGEST-INSTRUCTIONS"
        let contextSize = 4096
        let outputReserve = 1024 // mirrors MeetingDigestService.outputReserve
        let oldBudget = max(256, contextSize / 2)
        let newBudget = max(256, contextSize - instructions.count - outputReserve)

        let pad = String(repeating: "x", count: 1050)
        let seg1 = VoiceTranscriptSegment(
            id: "s1", text: pad, startSeconds: 0, endSeconds: 1,
            isFinal: true, confidence: nil, source: .microphone)
        let seg2 = VoiceTranscriptSegment(
            id: "s2", text: pad, startSeconds: 10, endSeconds: 11,
            isFinal: true, confidence: nil, source: .microphone)
        let combinedCost = MeetingDigestChunker.renderedLine(for: seg1).count
            + MeetingDigestChunker.renderedLine(for: seg2).count

        // Sanity check on the fixture itself: if this ever fails, the test
        // below would pass or fail for the wrong reason.
        XCTAssertGreaterThan(combinedCost, oldBudget, "fixture must overflow the old budget")
        XCTAssertLessThanOrEqual(combinedCost, newBudget, "fixture must fit the new budget")

        let stub = StubGenerating(results: [generated(summary: "One pass.")])
        let service = makeService(
            stub: stub, prompts: ["meeting-digest-27": instructions],
            tokenCount: { $0.count })

        let digest = try await service.digest(segments: [seg1, seg2], now: now).get()

        XCTAssertEqual(
            stub.recorder.prompts.count, 1,
            "the real budget fits both segments in one chunk; contextSize/2 "
                + "would have forced a split + reduce")
        XCTAssertEqual(digest.summary, "One pass.")
    }

    // MARK: - Utterance merging (BAK-329: near-word-level finals collapse before chunking)

    func test_manyTinyAdjacentSegments_mergeIntoFewerDigestChunksThanUnmerged() async throws {
        // 100 near-word-level finals, each 0.3s apart (well under the 1.5s
        // pause threshold) — exactly the shape the live transcriber emits.
        let segments = (0..<100).map { i in
            seg("s\(i)", "word here", start: Double(i) * 0.3)
        }
        let instructions = "DIGEST-INSTRUCTIONS"
        let tokenCount: @Sendable (String) -> Int = { $0.count }
        let outputReserve = MeetingDigestService.outputReserve
        let budget = max(256, 4096 - instructions.count - outputReserve)

        // What chunking would need WITHOUT merging — the pre-BAK-329 shape.
        let unmergedChunks = MeetingDigestChunker.chunks(
            segments: segments, budgetTokens: budget, tokenCount: tokenCount)
        XCTAssertGreaterThan(
            unmergedChunks.count, 1,
            "fixture must actually need multiple chunks before merging, or this test proves nothing")

        let action = GeneratedMeetingAction(
            title: "Follow up", owner: nil, dueISO8601: nil,
            evidenceSegmentIDs: [pid(segments[0])])
        let stub = StubGenerating(results: [generated(actions: [action])])
        let service = makeService(
            stub: stub, prompts: ["meeting-digest-27": instructions], tokenCount: tokenCount)

        let digest = try await service.digest(segments: segments, now: now).get()

        XCTAssertLessThan(
            stub.recorder.prompts.count, unmergedChunks.count,
            "merging adjacent same-source segments ahead of chunking must cut the digest call count")
        XCTAssertEqual(
            digest.actions.count, 1,
            "an action citing the first constituent's persistent id survives evidence validation")
        XCTAssertEqual(digest.actions.first?.evidenceSegmentIDs, [pid(segments[0])])
    }

    // MARK: - Partial degradation (BAK-330: one bad chunk never discards the rest)

    /// Three segments, each costing a flat 2000 "tokens" regardless of text —
    /// under a ~3052 budget that forces every segment into its own chunk
    /// (2000 + 2000 > 3052), deterministically, without needing a silence gap.
    private func threeChunkSegments() -> [VoiceTranscriptSegment] {
        [
            seg("seg-1", "first chunk", start: 0),
            seg("seg-2", "second chunk", start: 10),
            seg("seg-3", "third chunk", start: 20),
        ]
    }

    private func makeThreeChunkService(
        stub: StubGenerating
    ) -> MeetingDigestService {
        makeService(stub: stub, tokenCount: { _ in 2000 })
    }

    func test_middleChunkFails_othersSurvive_asAPartialDigestWithOmittedSpan() async throws {
        let segments = threeChunkSegments()
        let stub = StubGenerating(
            results: [
                generated(summary: "Part one."),
                generated(summary: "UNUSED — this chunk fails"),
                generated(summary: "Part three."),
                generated(summary: "Combined summary."),
            ],
            failures: [1: .modelNotReady])

        let digest = try await makeThreeChunkService(stub: stub)
            .digest(segments: segments, now: now).get()

        XCTAssertEqual(digest.summary, "Combined summary.", "the reduction sees only the successful partials")
        XCTAssertEqual(
            digest.omittedSpans, [segments[1].startSeconds...segments[1].endSeconds],
            "the failed chunk's own span is recorded as omitted")
        XCTAssertEqual(
            stub.recorder.prompts.count, 4,
            "3 map attempts (one throws) + 1 reduction over the 2 survivors")
    }

    func test_lastChunkFails_earlierSuccessesSurvive_reduceCombinesThem() async throws {
        let segments = threeChunkSegments()
        let stub = StubGenerating(
            results: [
                generated(summary: "Part one."),
                generated(summary: "Part two."),
                generated(summary: "UNUSED — this chunk fails"),
                generated(summary: "Combined summary."),
            ],
            failures: [2: .contextOverflow])

        let digest = try await makeThreeChunkService(stub: stub)
            .digest(segments: segments, now: now).get()

        XCTAssertEqual(digest.summary, "Combined summary.")
        XCTAssertEqual(digest.omittedSpans, [segments[2].startSeconds...segments[2].endSeconds])
    }

    func test_allChunksFail_returnsTheLastChunkFailure_asATypedFailure() async {
        let segments = threeChunkSegments()
        let stub = StubGenerating(
            results: [generated()],
            failures: [0: .modelNotReady, 1: .deviceNotEligible, 2: .contextOverflow])

        let result = await makeThreeChunkService(stub: stub).digest(segments: segments, now: now)

        guard case .failure(.model(.contextOverflow)) = result else {
            return XCTFail("expected the LAST chunk's failure (.contextOverflow), got \(result)")
        }
    }

    func test_reduceFailure_stillFailsTheWholeDigest_knownLimitation() async {
        // Every chunk succeeds individually but the reduction pass itself
        // fails — a documented limitation: partial-chunk collection only
        // covers the map phase, not the final reduce.
        let segments = threeChunkSegments()
        let stub = StubGenerating(
            results: [
                generated(summary: "Part one."),
                generated(summary: "Part two."),
                generated(summary: "Part three."),
            ],
            failures: [3: .unavailable("model hiccup")])

        let result = await makeThreeChunkService(stub: stub).digest(segments: segments, now: now)

        guard case .failure(.model(.unavailable("model hiccup"))) = result else {
            return XCTFail("expected the reduction's own failure to surface, got \(result)")
        }
    }

    // MARK: - Failures (typed, retryable)

    func test_modelUnavailable_failsWithoutGenerating() async {
        var stub = StubGenerating(results: [generated()])
        stub.capabilitiesResult = .failure(.modelNotReady)

        let result = await makeService(stub: stub)
            .digest(segments: [seg("seg-1", "hello")], now: now)

        guard case .failure(.model(.modelNotReady)) = result else {
            return XCTFail("expected model(.modelNotReady), got \(result)")
        }
        XCTAssertTrue(stub.recorder.prompts.isEmpty)
    }

    func test_unsupportedLocale_isATypedFailure() async {
        var stub = StubGenerating(results: [generated()])
        stub.capabilitiesResult = .failure(.unsupportedLocale)

        let result = await makeService(stub: stub)
            .digest(segments: [seg("seg-1", "hello")], now: now)

        guard case .failure(.model(.unsupportedLocale)) = result else {
            return XCTFail("expected model(.unsupportedLocale), got \(result)")
        }
    }

    func test_missingPromptResource_failsWithoutGenerating() async {
        let stub = StubGenerating(results: [generated()])
        let service = makeService(stub: stub, prompts: [:])

        let result = await service.digest(segments: [seg("seg-1", "hello")], now: now)

        guard case .failure(.missingPrompt) = result else {
            return XCTFail("expected missingPrompt, got \(result)")
        }
        XCTAssertTrue(stub.recorder.prompts.isEmpty)
    }
}
