import XCTest
import AVFoundation
import CoreMedia
import Speech
@testable import MustardKit

/// SpeechAnalyzer-backed transcription session (Voice Core Task 4). The live
/// analyzer/transcriber pair sits behind the injected `SpeechAnalyzerDriving`
/// seam; everything with a decision in it — provisional/final mapping,
/// attributed-string conversion, audio timing, confidence normalization,
/// context-term vocabulary, cancellation, finalization, and analyzer error
/// propagation — is pinned here against a deterministic stub driver.
final class AppleSpeechSessionTests: XCTestCase {

    // MARK: - Stub driver

    /// Deterministic `SpeechAnalyzerDriving` stand-in: the test drives the
    /// result stream by hand and records every forwarded call.
    private actor StubDriver: SpeechAnalyzerDriving {
        private(set) var startCount = 0
        private(set) var appendedFrameLengths: [AVAudioFrameCount] = []
        private(set) var contextCalls: [[String]] = []
        private(set) var finishInputCount = 0
        private(set) var cancelCount = 0
        private var continuation: AsyncThrowingStream<SpeechAnalysisResult, Error>.Continuation?

        func start() async throws -> AsyncThrowingStream<SpeechAnalysisResult, Error> {
            startCount += 1
            let (stream, continuation) = AsyncThrowingStream<SpeechAnalysisResult, Error>.makeStream()
            self.continuation = continuation
            return stream
        }

        func setContext(_ terms: [String]) async throws {
            contextCalls.append(terms)
        }

        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws {
            appendedFrameLengths.append(buffer.frameLength)
        }

        func finishInput() async throws {
            finishInputCount += 1
            continuation?.finish()
        }

        func cancel() async {
            cancelCount += 1
            continuation?.finish()
        }

        // Test controls.
        func yield(_ result: SpeechAnalysisResult) { continuation?.yield(result) }
        func fail(_ error: Error) { continuation?.finish(throwing: error) }
        func endResults() { continuation?.finish() }
    }

    private enum StubError: Error, Equatable {
        case analyzerFailed
    }

    // MARK: - Fixtures

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    @available(macOS 26.0, *)
    private static func attributedRun(
        _ text: String,
        confidence: Double? = nil,
        audioTimeRange: CMTimeRange? = nil
    ) -> AttributedString {
        var run = AttributedString(text)
        if let confidence {
            run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = confidence
        }
        if let audioTimeRange {
            run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = audioTimeRange
        }
        return run
    }

    private static func pcmBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    // MARK: - Provisional/final mapping

    func test_start_mapsProvisionalThenFinal_sharingSegmentID() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        let stream = try await session.start(source: .microphone)
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("Send the"), range: Self.range(1.2, 2.0), isFinal: false))
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("Send the notes"), range: Self.range(1.2, 2.8), isFinal: true))
        await driver.endResults()

        var segments: [VoiceTranscriptSegment] = []
        for try await segment in stream { segments.append(segment) }

        XCTAssertEqual(segments.count, 2)
        XCTAssertFalse(segments[0].isFinal)
        XCTAssertTrue(segments[1].isFinal)
        XCTAssertEqual(segments[0].text, "Send the")
        XCTAssertEqual(segments[1].text, "Send the notes")
        XCTAssertEqual(segments[0].id, segments[1].id,
                       "A final result replaces the provisional one for the same audio range, so both must share an id.")
        XCTAssertEqual(segments[0].source, .microphone)
    }

    func test_start_stampsMeetingSource() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        let stream = try await session.start(source: .meeting)
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("hello"), range: Self.range(0, 1), isFinal: true))
        await driver.endResults()

        var segments: [VoiceTranscriptSegment] = []
        for try await segment in stream { segments.append(segment) }
        XCTAssertEqual(segments.map(\.source), [.meeting])
    }

    func test_start_twice_throwsAlreadyStarted() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })
        _ = try await session.start(source: .microphone)

        do {
            _ = try await session.start(source: .microphone)
            XCTFail("Second start must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .alreadyStarted)
        }
    }

    // MARK: - Attributed-string conversion & audio time

    func test_segment_usesResultRangeForTiming() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let result = SpeechAnalysisResult(
            text: Self.attributedRun("Send the notes"),
            range: Self.range(1.2, 2.8),
            isFinal: true)

        let segment = AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0)

        let unwrapped = try XCTUnwrap(segment)
        XCTAssertEqual(unwrapped.startSeconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(unwrapped.endSeconds, 2.8, accuracy: 0.001)
        XCTAssertTrue(unwrapped.isFinal)
    }

    func test_segment_fallsBackToAttributeTimeRanges_whenResultRangeInvalid() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let text = Self.attributedRun("hello ", audioTimeRange: Self.range(0.5, 1.0))
            + Self.attributedRun("world", audioTimeRange: Self.range(1.0, 2.25))
        let result = SpeechAnalysisResult(text: text, range: .invalid, isFinal: true)

        let segment = AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0)

        let unwrapped = try XCTUnwrap(segment)
        XCTAssertEqual(unwrapped.startSeconds, 0.5, accuracy: 0.001,
                       "Timing must fall back to the union of per-run audioTimeRange attributes.")
        XCTAssertEqual(unwrapped.endSeconds, 2.25, accuracy: 0.001)
    }

    // MARK: - Confidence normalization

    func test_segment_averagesRunConfidences() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let text = Self.attributedRun("hello ", confidence: 0.8)
            + Self.attributedRun("world", confidence: 0.6)
        let result = SpeechAnalysisResult(text: text, range: Self.range(0, 1), isFinal: true)

        let segment = AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0)

        let confidence = try XCTUnwrap(segment?.confidence)
        XCTAssertEqual(confidence, 0.7, accuracy: 0.001)
    }

    func test_segment_clampsConfidenceIntoUnitInterval() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let text = Self.attributedRun("loud", confidence: 1.4)
        let result = SpeechAnalysisResult(text: text, range: Self.range(0, 1), isFinal: true)

        let segment = AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0)

        let confidence = try XCTUnwrap(segment?.confidence)
        XCTAssertEqual(confidence, 1.0, accuracy: 0.0001,
                       "Recognizer scores outside 0...1 must be clamped, not passed through.")
    }

    func test_segment_confidenceIsNilWhenNoRunCarriesTheAttribute() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let result = SpeechAnalysisResult(
            text: Self.attributedRun("unscored"), range: Self.range(0, 1), isFinal: true)

        let segment = AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0)

        XCTAssertNil(segment?.confidence,
                     "Absent confidence is distinct from zero and must stay nil.")
    }

    func test_segment_dropsWhitespaceOnlyText() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let result = SpeechAnalysisResult(
            text: Self.attributedRun("  \n "), range: Self.range(0, 1), isFinal: true)

        XCTAssertNil(AppleSpeechSession.segment(from: result, source: .microphone, fallbackIndex: 0))
    }

    // MARK: - Finalization

    func test_finish_returnsOnlyFinalSegments_orderedByStartTime() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        let stream = try await session.start(source: .microphone)
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("provisional"), range: Self.range(0.1, 0.4), isFinal: false))
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("second"), range: Self.range(2.0, 3.0), isFinal: true))
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("first"), range: Self.range(0.5, 1.5), isFinal: true))

        let finals = try await session.finish()

        XCTAssertEqual(finals.map(\.text), ["first", "second"],
                       "finish() must return only final segments, ordered by start time.")
        let finishCalls = await driver.finishInputCount
        XCTAssertEqual(finishCalls, 1)

        // The caller-facing stream also drains cleanly after finish.
        var streamed: [VoiceTranscriptSegment] = []
        for try await segment in stream { streamed.append(segment) }
        XCTAssertEqual(streamed.count, 3)
    }

    func test_finish_beforeStart_throwsNotStarted() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let session = AppleSpeechSession(
            driver: StubDriver(), readiness: { .ready }, prepare: { .ready })

        do {
            _ = try await session.finish()
            XCTFail("finish() before start must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .notStarted)
        }
    }

    // MARK: - Analyzer errors

    func test_stream_throwsWhenAnalyzerFails() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        let stream = try await session.start(source: .microphone)
        await driver.yield(SpeechAnalysisResult(
            text: Self.attributedRun("partial"), range: Self.range(0, 1), isFinal: false))
        await driver.fail(StubError.analyzerFailed)

        var segments: [VoiceTranscriptSegment] = []
        do {
            for try await segment in stream { segments.append(segment) }
            XCTFail("The session stream must rethrow analyzer errors")
        } catch let error as StubError {
            XCTAssertEqual(error, .analyzerFailed)
        }
        XCTAssertEqual(segments.count, 1, "Results before the failure still surface.")
    }

    // MARK: - Cancellation

    func test_cancel_forwardsToDriver_andEndsStreamWithoutError() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        let stream = try await session.start(source: .microphone)
        await session.cancel()

        var segments: [VoiceTranscriptSegment] = []
        for try await segment in stream { segments.append(segment) }
        XCTAssertTrue(segments.isEmpty)
        let cancels = await driver.cancelCount
        XCTAssertEqual(cancels, 1)
    }

    // MARK: - Audio input forwarding

    func test_append_beforeStart_throwsNotStarted() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let session = AppleSpeechSession(
            driver: StubDriver(), readiness: { .ready }, prepare: { .ready })

        do {
            try await session.append(Self.pcmBuffer(frames: 160), at: nil)
            XCTFail("append() before start must throw")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .notStarted)
        }
    }

    func test_append_afterStart_forwardsBufferToDriver() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        _ = try await session.start(source: .microphone)
        try await session.append(Self.pcmBuffer(frames: 160), at: nil)
        try await session.append(Self.pcmBuffer(frames: 320), at: nil)

        let forwarded = await driver.appendedFrameLengths
        XCTAssertEqual(forwarded, [160, 320])
    }

    // MARK: - Readiness / prepare

    func test_readiness_reportsInjectedState_withoutInstalling() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let session = AppleSpeechSession(
            driver: StubDriver(),
            readiness: { .needsAssetDownload },
            prepare: { .ready })

        let readiness = await session.readiness()
        XCTAssertEqual(readiness, .needsAssetDownload)
    }

    func test_prepare_throwsNotReady_whenAssetsUnavailable() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let session = AppleSpeechSession(
            driver: StubDriver(),
            readiness: { .permissionDenied },
            prepare: { .permissionDenied })

        do {
            try await session.prepare()
            XCTFail("prepare() must throw when preparation does not end .ready")
        } catch let error as VoiceSessionError {
            XCTAssertEqual(error, .notReady(.permissionDenied))
        }
    }

    func test_prepare_succeedsWhenAssetsReady() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let session = AppleSpeechSession(
            driver: StubDriver(), readiness: { .ready }, prepare: { .ready })
        try await session.prepare()
    }

    // MARK: - Contextual vocabulary

    func test_setContext_normalizesTermsBeforeForwarding() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let driver = StubDriver()
        let session = AppleSpeechSession(
            driver: driver, readiness: { .ready }, prepare: { .ready })

        try await session.setContext([
            "  Mustard  ", "", "mustard", "Code Heroes", "   ", "Acme", "Code Heroes",
        ])

        let calls = await driver.contextCalls
        XCTAssertEqual(calls, [["Mustard", "Code Heroes", "Acme"]],
                       "Terms must be trimmed, de-duplicated case-insensitively (first casing wins), and forwarded once.")
    }

    func test_contextVocabulary_truncatesDeterministicallyAtLimit() {
        let terms = (0..<80).map { "term-\($0)" }

        let normalized = VoiceContextVocabulary.normalized(terms, limit: 64)

        XCTAssertEqual(normalized.count, 64)
        XCTAssertEqual(normalized.first, "term-0")
        XCTAssertEqual(normalized.last, "term-63",
                       "Truncation keeps the earliest terms — deterministic, order-preserving.")
    }

    func test_contextVocabulary_defaultLimitIsBounded() {
        let terms = (0..<500).map { "term-\($0)" }
        XCTAssertLessThanOrEqual(VoiceContextVocabulary.normalized(terms).count,
                                 VoiceContextVocabulary.defaultLimit)
    }
}
