import Foundation
import AVFoundation
import CoreMedia
import Speech

/// SpeechAnalyzer-backed transcription session (Voice Core Task 4). The
/// session owns all mapping decisions — provisional/final segments, timing,
/// confidence normalization, contextual vocabulary — while the Apple
/// `SpeechAnalyzer`/`SpeechTranscriber` pair stays behind the injected
/// `SpeechAnalyzerDriving` seam so every decision is unit-tested without a
/// microphone or downloaded speech assets. Audio never leaves the machine:
/// the analyzer family is on-device by construction.

// MARK: - Analyzer seam

/// One raw result off the analyzer, before Mustard mapping. Deliberately
/// framework-light (AttributedString + CMTimeRange) so tests can construct
/// it directly; the live driver builds it from `Speech.SpeechTranscriber.Result`.
public struct SpeechAnalysisResult: Sendable {
    /// Transcribed text, carrying the Speech attribute-scope runs
    /// (`audioTimeRange`, `transcriptionConfidence`) when requested.
    public let text: AttributedString
    /// The audio range this result covers. May be invalid for some
    /// recognizer paths — mapping then falls back to the attribute runs.
    public let range: CMTimeRange
    /// Volatile results are `false` and later replaced; finalized results
    /// are `true` and never revised.
    public let isFinal: Bool

    public init(text: AttributedString, range: CMTimeRange, isFinal: Bool) {
        self.text = text
        self.range = range
        self.isFinal = isFinal
    }
}

/// The live-analyzer seam: `AppleSpeechAnalyzerDriver` conforms on macOS 27;
/// tests inject a deterministic stub. Implementations own the analyzer
/// lifecycle and must finish the result stream on `finishInput`/`cancel`.
public protocol SpeechAnalyzerDriving: Sendable {
    func start() async throws -> AsyncThrowingStream<SpeechAnalysisResult, Error>
    func setContext(_ terms: [String]) async throws
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws
    func finishInput() async throws
    func cancel() async
}

/// Session lifecycle errors surfaced to feature coordinators.
public enum VoiceSessionError: Error, Equatable {
    case notReady(VoiceReadiness)
    case notStarted
    case alreadyStarted
    case audioFormatUnavailable
    /// The audio engine refused to start — an NSException AVFAudio raised
    /// (stale device format across sleep/wake, device mid-switch), caught by
    /// `MSTDCatchException` and converted so it can never unwind through
    /// async frames. The payload is the exception's reason.
    case audioEngineFailure(String)
}

extension VoiceSessionError: LocalizedError {
    /// The capture/dictation pill shows `localizedDescription` as the
    /// recovery reason — these two must read as instructions, not codes.
    public var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            return "The microphone's audio format is changing — try again in a moment."
        case .audioEngineFailure(let reason):
            return "The microphone couldn't start (\(reason)) — try again."
        case .notReady, .notStarted, .alreadyStarted:
            return nil
        }
    }
}

// MARK: - Contextual vocabulary

/// Normalizes caller-supplied contextual vocabulary (area/project/contact
/// names) before it reaches the analyzer: trimmed, empties dropped,
/// de-duplicated case-insensitively (first casing wins), and truncated to a
/// deterministic bound so an unbounded task list can't degrade recognition.
public enum VoiceContextVocabulary {
    public static let defaultLimit = 64

    public static func normalized(_ terms: [String], limit: Int = defaultLimit) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            kept.append(trimmed)
            if kept.count == limit { break }
        }
        return kept
    }
}

// MARK: - Session

/// The `VoiceTranscribing` adapter over an injected analyzer driver. An actor
/// so provisional/final bookkeeping and lifecycle flags stay race-free while
/// the driver's result stream is consumed concurrently.
@available(macOS 26.0, iOS 26.0, *)
public actor AppleSpeechSession: VoiceTranscribing {
    private let driver: any SpeechAnalyzerDriving
    private let readinessProbe: @Sendable () async -> VoiceReadiness
    private let prepareAssets: @Sendable () async -> VoiceReadiness

    private var started = false
    private var finalSegments: [String: VoiceTranscriptSegment] = [:]
    private var consumeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - driver: the analyzer seam (live on macOS 27, stub in tests).
    ///   - readiness: passive availability check — must not download assets.
    ///   - prepare: performs asset installation (`VoiceAssetReadiness.prepare`)
    ///     and reports the resulting state.
    public init(
        driver: any SpeechAnalyzerDriving,
        readiness: @escaping @Sendable () async -> VoiceReadiness,
        prepare: @escaping @Sendable () async -> VoiceReadiness
    ) {
        self.driver = driver
        self.readinessProbe = readiness
        self.prepareAssets = prepare
    }

    public func readiness() async -> VoiceReadiness {
        await readinessProbe()
    }

    public func prepare() async throws {
        let outcome = await prepareAssets()
        guard outcome == .ready else { throw VoiceSessionError.notReady(outcome) }
    }

    public func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error> {
        guard !started else { throw VoiceSessionError.alreadyStarted }
        started = true

        let results = try await driver.start()
        let (stream, continuation) = AsyncThrowingStream<VoiceTranscriptSegment, Error>.makeStream()
        consumeTask = Task {
            var fallbackIndex = 0
            do {
                for try await result in results {
                    guard let segment = Self.segment(
                        from: result, source: source, fallbackIndex: fallbackIndex) else { continue }
                    fallbackIndex += 1
                    await self.record(segment)
                    continuation.yield(segment)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws {
        guard started else { throw VoiceSessionError.notStarted }
        try await driver.append(buffer, at: time)
    }

    public func finish() async throws -> [VoiceTranscriptSegment] {
        guard started else { throw VoiceSessionError.notStarted }
        try await driver.finishInput()
        await consumeTask?.value
        return finalSegments.values.sorted {
            ($0.startSeconds, $0.id) < ($1.startSeconds, $1.id)
        }
    }

    public func cancel() async {
        await driver.cancel()
        await consumeTask?.value
    }

    /// Forwards normalized contextual vocabulary (see
    /// `VoiceContextVocabulary`) to the analyzer. Callable before or after
    /// `start` — the driver applies or defers as needed.
    public func setContext(_ terms: [String]) async throws {
        try await driver.setContext(VoiceContextVocabulary.normalized(terms))
    }

    private func record(_ segment: VoiceTranscriptSegment) {
        guard segment.isFinal else { return }
        finalSegments[segment.id] = segment
    }

    // MARK: Result mapping (pure)

    /// Maps one analyzer result to a Mustard segment, or nil for
    /// whitespace-only text. Timing prefers the result's own range and falls
    /// back to the union of per-run `audioTimeRange` attributes; the id is
    /// derived from the start time so a final result replaces the
    /// provisional one for the same audio span. Confidence is the mean of
    /// the per-run scores clamped into 0...1, and stays nil when no run is
    /// scored (absence is distinct from zero).
    static func segment(
        from result: SpeechAnalysisResult,
        source: VoiceAudioSource,
        fallbackIndex: Int
    ) -> VoiceTranscriptSegment? {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let span = timeSpan(of: result)
        let id: String
        if let span {
            id = String(format: "seg-%.3f", span.start)
        } else {
            id = "seg-#\(fallbackIndex)"
        }

        return VoiceTranscriptSegment(
            id: id,
            text: text,
            startSeconds: span?.start ?? 0,
            endSeconds: span?.end ?? 0,
            isFinal: result.isFinal,
            confidence: normalizedConfidence(of: result.text),
            source: source)
    }

    private static func timeSpan(of result: SpeechAnalysisResult) -> (start: Double, end: Double)? {
        if result.range.isValid, !result.range.isIndefinite {
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(result.range.end)
            if start.isFinite, end.isFinite { return (start, end) }
        }

        var earliest: Double?
        var latest: Double?
        for (range, _) in result.text.runs[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
            guard let range, range.isValid, !range.isIndefinite else { continue }
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.end)
            guard start.isFinite, end.isFinite else { continue }
            earliest = min(earliest ?? start, start)
            latest = max(latest ?? end, end)
        }
        guard let earliest, let latest else { return nil }
        return (earliest, latest)
    }

    private static func normalizedConfidence(of text: AttributedString) -> Double? {
        var scores: [Double] = []
        for (confidence, _) in text.runs[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
            guard let confidence else { continue }
            scores.append(min(max(confidence, 0), 1))
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}

// MARK: - Live asset readiness (Task 3's injected closures, wired)

@available(macOS 26.0, iOS 26.0, *)
extension VoiceAssetReadiness {
    /// The production closures: locale resolution via the transcriber's
    /// supported-locale table, installation via `AssetInventory` (a no-op
    /// when the assets are already on disk).
    public static func live() -> VoiceAssetReadiness {
        VoiceAssetReadiness(
            resolveLocale: { locale in
                await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale)
            },
            installAssets: { locale in
                let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            })
    }
}

// MARK: - Live driver (macOS 27)

/// The production `SpeechAnalyzerDriving`: one `SpeechAnalyzer` with a
/// `SpeechTranscriber` (volatile results + alternatives, time/confidence
/// attributes) and a `SpeechDetector`, fed `AnalyzerInput` through a single
/// `AsyncStream` after `AnalyzerInputResampler` resamples the caller's PCM
/// buffers to the analyzer's preferred format.
///
/// The `macOS 27` gate is now conservative rather than forced: it was here
/// because `Speech.AnalyzerInputConverter` was a 27-only symbol, and that type
/// no longer exists in any current SDK (see `AnalyzerInputResampler`). Nothing
/// in this driver needs more than macOS 26 any more, but dropping the gate would
/// switch voice capture on for macOS 26 users, which is a product change and not
/// this fix's business.
@available(macOS 27.0, iOS 27.0, *)
public actor AppleSpeechAnalyzerDriver: SpeechAnalyzerDriving {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var resampler: AnalyzerInputResampler?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Context set before `start` is applied as soon as the analyzer exists.
    private var pendingContextTerms: [String]?

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public func start() async throws -> AsyncThrowingStream<SpeechAnalysisResult, Error> {
        let transcriber = Speech.SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `.fastResults` is load-bearing, not a tuning knob: WITHOUT it the
            // transcriber batches everything and emits nothing until input is
            // finished, so a live surface shows an empty pill for the whole
            // capture and the entire transcript lands in one burst at the end.
            // With it, volatile updates arrive roughly every second while audio
            // keeps arriving. Verified against a file-fed harness on macOS 27:
            // results at 1.2s/2.1s/3.1s of a 4s feed, versus nothing until 6.1s.
            reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let detector = SpeechDetector()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector]) else {
            throw VoiceSessionError.audioFormatUnavailable
        }
        let resampler = try AnalyzerInputResampler(analyzerFormat: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber, detector])

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)
        if let terms = pendingContextTerms {
            pendingContextTerms = nil
            try await Self.applyContext(terms, to: analyzer)
        }

        self.analyzer = analyzer
        self.resampler = resampler
        self.inputContinuation = inputContinuation

        let (stream, continuation) = AsyncThrowingStream<SpeechAnalysisResult, Error>.makeStream()
        let consume = Task {
            do {
                for try await result in transcriber.results {
                    continuation.yield(SpeechAnalysisResult(
                        text: result.text, range: result.range, isFinal: result.isFinal))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in consume.cancel() }
        return stream
    }

    public func setContext(_ terms: [String]) async throws {
        guard let analyzer else {
            pendingContextTerms = terms
            return
        }
        try await Self.applyContext(terms, to: analyzer)
    }

    /// `time` is intentionally not forwarded: the resampler stamps every buffer
    /// onto its own capture-relative timeline, because the caller's tap/host
    /// timebase has an unrelated origin and segment ids are derived from the
    /// start time. See `AnalyzerInputResampler.nextStartFrame`.
    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws {
        guard let resampler, let inputContinuation else { throw VoiceSessionError.notStarted }
        for input in try resampler.convert(buffer) {
            inputContinuation.yield(input)
        }
    }

    public func finishInput() async throws {
        guard let analyzer, let resampler, let inputContinuation else {
            throw VoiceSessionError.notStarted
        }
        for input in try resampler.flush() {
            inputContinuation.yield(input)
        }
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    public func cancel() async {
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resampler = nil
        inputContinuation = nil
    }

    private static func applyContext(_ terms: [String], to analyzer: SpeechAnalyzer) async throws {
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        try await analyzer.setContext(context)
    }
}

// MARK: - Live session factory

@available(macOS 27.0, iOS 27.0, *)
extension AppleSpeechSession {
    /// The production session: live analyzer driver plus live asset
    /// readiness for the (transcriber-supported equivalent of the) locale.
    public static func live(locale: Locale = .current) -> AppleSpeechSession {
        let assets = VoiceAssetReadiness.live()
        return AppleSpeechSession(
            driver: AppleSpeechAnalyzerDriver(locale: locale),
            readiness: { await liveReadiness(locale: locale) },
            prepare: { await assets.prepare(locale: locale) })
    }

    /// Passive readiness: reports whether transcription could start now
    /// without triggering any download.
    private static func liveReadiness(locale: Locale) async -> VoiceReadiness {
        guard Speech.SpeechTranscriber.isAvailable else {
            return .unavailable("Speech transcription is not available on this Mac")
        }
        guard let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupportedLocale
        }
        let transcriber = Speech.SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsAssetDownload
        case .unsupported:
            return .unsupportedLocale
        @unknown default:
            return .unavailable("Unrecognized speech asset status")
        }
    }
}
