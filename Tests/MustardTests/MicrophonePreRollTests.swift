import XCTest
@testable import MustardKit

/// Pre-roll sizing for the microphone ring buffer (Talkify review, item 1).
///
/// The feed now installs the mic tap BEFORE the analyzer session exists, so
/// audio spoken during session start is buffered instead of lost. The buffer
/// must be big enough to cover a slow analyzer start and small enough that a
/// wedged one cannot grow without bound — this pins that trade-off instead of
/// leaving a bare magic number in the audio code.
final class MicrophonePreRollTests: XCTestCase {

    // MARK: - Buffered duration

    func test_bufferedSeconds_atTheDefaultCapCoversASlowAnalyzerStart() {
        let seconds = MicrophonePreRoll.bufferedSeconds(sampleRate: 48_000)

        // 128 chunks × 2048 frames ÷ 48kHz ≈ 5.46s.
        XCTAssertEqual(seconds, 5.461, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            seconds, MicrophonePreRoll.minimumCoveredSeconds,
            "the cap must cover the worst analyzer start we are willing to tolerate")
    }

    /// The other common hardware rate buffers *more* wall-clock, never less.
    func test_bufferedSeconds_atLowerSampleRatesCoversAtLeastAsMuchTime() {
        let at48k = MicrophonePreRoll.bufferedSeconds(sampleRate: 48_000)
        let at44k = MicrophonePreRoll.bufferedSeconds(sampleRate: 44_100)

        XCTAssertGreaterThan(at44k, at48k)
        XCTAssertGreaterThanOrEqual(at44k, MicrophonePreRoll.minimumCoveredSeconds)
    }

    func test_bufferedSeconds_scalesWithTheChunkCount() {
        let single = MicrophonePreRoll.bufferedSeconds(sampleRate: 48_000, chunks: 1)
        let double = MicrophonePreRoll.bufferedSeconds(sampleRate: 48_000, chunks: 2)

        XCTAssertEqual(double, single * 2, accuracy: 0.000_1)
    }

    /// A device mid-switch can report a degenerate format; the feed refuses to
    /// start on one, but this arithmetic must not divide by zero if it is ever
    /// called with one.
    func test_bufferedSeconds_isZeroForADegenerateSampleRate() {
        XCTAssertEqual(MicrophonePreRoll.bufferedSeconds(sampleRate: 0), 0)
        XCTAssertEqual(MicrophonePreRoll.bufferedSeconds(sampleRate: -48_000), 0)
    }

    func test_bufferedSeconds_isZeroForANonPositiveFrameCount() {
        XCTAssertEqual(
            MicrophonePreRoll.bufferedSeconds(sampleRate: 48_000, framesPerChunk: 0), 0)
    }

    // MARK: - Chunks needed for a target duration

    func test_chunkCount_roundsUpSoTheTargetIsAlwaysCovered() {
        // 1s at 48kHz needs 23.4 chunks of 2048 frames — 24, never 23.
        XCTAssertEqual(
            MicrophonePreRoll.chunkCount(forSeconds: 1, sampleRate: 48_000), 24)
    }

    func test_chunkCount_isAtLeastOneForAnyPositiveTarget() {
        XCTAssertEqual(
            MicrophonePreRoll.chunkCount(forSeconds: 0.000_1, sampleRate: 48_000), 1)
    }

    func test_chunkCount_isZeroForANonPositiveTarget() {
        XCTAssertEqual(
            MicrophonePreRoll.chunkCount(forSeconds: 0, sampleRate: 48_000), 0)
        XCTAssertEqual(
            MicrophonePreRoll.chunkCount(forSeconds: -1, sampleRate: 48_000), 0)
    }

    func test_chunkCount_isZeroForADegenerateSampleRate() {
        XCTAssertEqual(
            MicrophonePreRoll.chunkCount(forSeconds: 1, sampleRate: 0), 0)
    }

    // MARK: - The default cap itself

    func test_defaultCap_isEnoughForTheMinimumCoveredDurationAtBothCommonRates() {
        for rate in [44_100.0, 48_000.0] {
            let needed = MicrophonePreRoll.chunkCount(
                forSeconds: MicrophonePreRoll.minimumCoveredSeconds, sampleRate: rate)
            XCTAssertLessThanOrEqual(
                needed, MicrophonePreRoll.maxBufferedChunks,
                "the default cap must cover \(MicrophonePreRoll.minimumCoveredSeconds)s at \(rate)Hz")
        }
    }
}
