import XCTest
@testable import MustardKit

/// Typed on-device voice-task drafting (Capture Task 2, BAK-282). The generator
/// gates on model availability, selects the banded prompt resource, grounds the
/// prompt in an injected "now"/calendar, and funnels every model string through
/// `VoiceTaskDrafting` — a failure is always retryable-local and never mutates
/// anything.
final class VoiceTaskDraftGeneratorTests: XCTestCase {

    // MARK: - Fixtures (pinned time & timezone; never the ambient clock)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Pin the locale so weekdaySymbols are stable full English names
        // (house convention for date-grounded prompt tests).
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-07-29T12:00:00Z — a Wednesday.
    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-07-29T12:00:00Z")!
    }

    private func generated(
        title: String = "Call the plumber",
        notes: String? = nil,
        areaName: String? = nil,
        scheduledISO8601: String? = nil,
        urls: [String] = []
    ) -> GeneratedVoiceTaskDraft {
        GeneratedVoiceTaskDraft(
            title: title,
            notes: notes,
            areaName: areaName,
            scheduledISO8601: scheduledISO8601,
            urls: urls
        )
    }

    private func makeGenerator(
        stub: StubGenerating,
        prompts: [String: String] = ["voice-task-27": "INSTRUCTIONS-27"],
        band: PromptBand = .macOS27
    ) -> VoiceTaskDraftGenerator {
        VoiceTaskDraftGenerator(
            service: stub,
            calendar: utc,
            locale: Locale(identifier: "en_AU"),
            promptBand: band,
            loadPrompt: { prompts[$0] }
        )
    }

    private func draft(
        _ generator: VoiceTaskDraftGenerator,
        transcript: String = "call the plumber",
        allowedAreas: [String] = ["Code Heroes", "Personal"]
    ) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure> {
        await generator.draft(transcript: transcript, allowedAreas: allowedAreas, now: now)
    }

    // MARK: - Happy path

    func testPlainTaskProducesValidatedDraft() async {
        let stub = StubGenerating(returning: generated(title: "  Call   the plumber "))
        let result = await draft(makeGenerator(stub: stub))
        XCTAssertEqual(try? result.get(), VoiceTaskDraft(title: "Call the plumber"))
    }

    func testGeneratedURLsAreValidatedAndDeduplicated() async {
        let stub = StubGenerating(returning: generated(
            urls: ["https://example.com/doc", "not a url", "https://example.com/doc", "ftp://x.com/y"]
        ))
        let result = await draft(makeGenerator(stub: stub))
        XCTAssertEqual(try? result.get().urls, [URL(string: "https://example.com/doc")!])
    }

    func testDateOnlyScheduleResolvesToNineAMInInjectedZone() async {
        let stub = StubGenerating(returning: generated(scheduledISO8601: "2026-07-30"))
        let result = await draft(makeGenerator(stub: stub))
        XCTAssertEqual(
            try? result.get().scheduledDate,
            ISO8601DateFormatter().date(from: "2026-07-30T09:00:00Z")!
        )
    }

    func testUnknownAreaIsDropped() async {
        let stub = StubGenerating(returning: generated(areaName: "Marketing"))
        let result = await draft(makeGenerator(stub: stub))
        XCTAssertNil(try? result.get().areaName ?? nil)
    }

    func testKnownAreaCanonicalizesToAllowedSpelling() async {
        let stub = StubGenerating(returning: generated(areaName: "code heroes"))
        let result = await draft(makeGenerator(stub: stub))
        XCTAssertEqual(try? result.get().areaName ?? nil, "Code Heroes")
    }

    func testFabricatedURLsAreDroppedEvenWhenWellFormed() async {
        // The failure seen in real use: a valid-looking link for a sentence
        // that mentioned no site.
        let stub = StubGenerating(returning: generated(urls: ["http://example.com"]))
        let result = await draft(
            makeGenerator(stub: stub),
            transcript: "okay this is a test to see if this is now transcribing")
        XCTAssertEqual(try? result.get().urls, [], "the model may not invent links")
    }

    func testSpokenURLsSurvive() async {
        let stub = StubGenerating(returning: generated(urls: ["https://coles.com.au"]))
        let result = await draft(
            makeGenerator(stub: stub), transcript: "grab the coles.com.au specials")
        XCTAssertEqual(try? result.get().urls, [URL(string: "https://coles.com.au")!])
    }

    // MARK: - Invalid structured output

    func testMissingTitleIsInvalidOutput() async {
        let stub = StubGenerating(returning: generated(title: "   "))
        let result = await draft(makeGenerator(stub: stub))
        guard case .failure(.invalidOutput) = result else {
            return XCTFail("expected invalidOutput, got \(result)")
        }
    }

    // MARK: - Model availability & generation failures (all retryable-local)

    func testModelUnavailableFailsWithoutGenerating() async {
        let stub = StubGenerating(
            capabilities: .failure(.modelNotReady),
            returning: generated()
        )
        let result = await draft(makeGenerator(stub: stub))
        guard case .failure(.model(.modelNotReady)) = result else {
            return XCTFail("expected model(.modelNotReady), got \(result)")
        }
        XCTAssertFalse(stub.recorder.generateCalled, "must not generate when the model is unavailable")
    }

    func testGenerationFailureMapsToModelFailure() async {
        let stub = StubGenerating(throwing: LocalModelFailure.contextOverflow)
        let result = await draft(makeGenerator(stub: stub))
        guard case .failure(.model(.contextOverflow)) = result else {
            return XCTFail("expected model(.contextOverflow), got \(result)")
        }
    }

    func testUnknownGenerationErrorBecomesUnavailable() async {
        let stub = StubGenerating(throwing: NSError(domain: "test", code: 1))
        let result = await draft(makeGenerator(stub: stub))
        guard case .failure(.model(.unavailable)) = result else {
            return XCTFail("expected model(.unavailable), got \(result)")
        }
    }

    // MARK: - Prompt assembly

    func testPromptCarriesTranscriptAreasAndPinnedDate() async {
        let stub = StubGenerating(returning: generated())
        _ = await draft(
            makeGenerator(stub: stub),
            transcript: "book flights to Sydney",
            allowedAreas: ["Code Heroes"]
        )
        let prompt = stub.recorder.prompt ?? ""
        XCTAssertTrue(prompt.contains("book flights to Sydney"), "prompt must carry the raw transcript")
        XCTAssertTrue(prompt.contains("\"Code Heroes\""), "prompt must list allowed areas")
        XCTAssertTrue(prompt.contains("Wednesday 2026-07-29"), "prompt must pin today via the injected calendar")
        // The UTC fixture zone surfaces as GMT on some OS builds.
        XCTAssertTrue(prompt.contains("GMT") || prompt.contains("UTC"), "prompt must name the injected timezone")
        XCTAssertEqual(stub.recorder.instructions, "INSTRUCTIONS-27")
    }

    func testPromptResourceFallsBackDownwardOnly() async {
        let stub = StubGenerating(returning: generated())
        let generator = makeGenerator(
            stub: stub,
            prompts: ["voice-task-26": "INSTRUCTIONS-26"],
            band: .macOS27
        )
        _ = await draft(generator)
        XCTAssertEqual(stub.recorder.instructions, "INSTRUCTIONS-26")
    }

    func testMissingPromptResourceFailsWithoutGenerating() async {
        let stub = StubGenerating(returning: generated())
        let generator = makeGenerator(stub: stub, prompts: [:])
        let result = await draft(generator)
        guard case .failure(.missingPrompt) = result else {
            return XCTFail("expected missingPrompt, got \(result)")
        }
        XCTAssertFalse(stub.recorder.generateCalled)
    }
}

// MARK: - Stub generation seam

/// Captures what the generator sent to the model; results are canned.
private final class StubRecorder: @unchecked Sendable {
    var instructions: String?
    var prompt: String?
    var generateCalled = false
}

private struct StubGenerating: OnDeviceGenerating {
    let recorder = StubRecorder()
    private let capabilitiesResult: Result<LocalModelCapabilities, LocalModelFailure>
    private let outcome: Result<GeneratedVoiceTaskDraft, Error>

    init(
        capabilities: Result<LocalModelCapabilities, LocalModelFailure> = .success(
            LocalModelCapabilities(contextSize: 4096, promptBand: "27", osBuild: "test")
        ),
        returning draft: GeneratedVoiceTaskDraft
    ) {
        capabilitiesResult = capabilities
        outcome = .success(draft)
    }

    init(throwing error: Error) {
        capabilitiesResult = .success(
            LocalModelCapabilities(contextSize: 4096, promptBand: "27", osBuild: "test"))
        outcome = .failure(error)
    }

    func capabilities(locale: Locale) async -> Result<LocalModelCapabilities, LocalModelFailure> {
        capabilitiesResult
    }

    func generate<Output>(
        _ type: Output.Type, instructions: String, prompt: String
    ) async throws -> Output {
        recorder.generateCalled = true
        recorder.instructions = instructions
        recorder.prompt = prompt
        return try outcome.get() as! Output
    }
}
