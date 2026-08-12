import XCTest
import AVFoundation
import CoreMedia
import Speech
@testable import MustardKit

/// `AnalyzerInputResampler` replaces `Speech.AnalyzerInputConverter`, which the
/// macOS 28 SDK removed. It is the one piece of the live analyzer path that can
/// be exercised without a microphone or downloaded speech assets — synthetic PCM
/// in, `AnalyzerInput` out — so every decision in it is pinned here: the output
/// format, the resampled frame count, the capture-relative timeline, mid-capture
/// format changes, and the end-of-input flush.
///
/// **The formats here are not arbitrary.** The analyzer side is 16 kHz mono
/// **Int16 interleaved** because that is what
/// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` actually reports
/// (measured on macOS 27.0/26A5388g), and the source side is float32 because
/// that is what an `AVAudioEngine` input tap hands over. Substituting the more
/// obvious `AVAudioFormat(standardFormatWithSampleRate:channels:)` for the
/// analyzer format makes these tests *crash the whole test process* rather than
/// fail: `AnalyzerInput.init(buffer:…)` traps on float PCM. Keep them honest.
final class AnalyzerInputResamplerTests: XCTestCase {

    // MARK: - Fixtures

    /// The analyzer's side of the conversion, matching `bestAvailableAudioFormat`.
    private static func analyzerFormat(
        rate: Double = 16_000, channels: AVAudioChannelCount = 1
    ) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: rate,
            channels: channels, interleaved: true)!
    }

    /// A tap-shaped source buffer carrying audible content — a 440 Hz sine
    /// rather than silence, so a conversion that dropped its input is visible.
    private static func tone(
        rate: Double,
        channels: AVAudioChannelCount = 1,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        return fill(format, frames: frames)
    }

    private static func fill(
        _ format: AVAudioFormat, frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let stride = buffer.stride
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let sample = sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate)
                if let float = buffer.floatChannelData {
                    float[channel][frame * stride] = Float(sample) * 0.5
                } else if let int16 = buffer.int16ChannelData {
                    int16[channel][frame * stride] = Int16(sample * 8_000)
                }
            }
        }
        return buffer
    }

    /// Loudest absolute sample, normalized to 0...1 across Int16 and float.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else { return 0 }
        let stride = buffer.stride
        var loudest = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            if let int16 = buffer.int16ChannelData {
                loudest = max(loudest, abs(Double(int16[0][frame * stride])) / 32_768)
            } else if let float = buffer.floatChannelData {
                loudest = max(loudest, abs(Double(float[0][frame * stride])))
            }
        }
        return loudest
    }

    private static func totalFrames(_ inputs: [AnalyzerInput]) -> Int {
        inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
    }

    // MARK: - Analyzer-format guard

    func test_init_rejectsAFloatAnalyzerFormat_ratherThanTrappingLater() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        // `AnalyzerInput.init(buffer:…)` traps (EXC_BREAKPOINT inside
        // `AnalyzerInput.data(from:)`) on float PCM, which no `do/catch` can
        // contain — so the format is refused up front, at `start()`, where the
        // pill can show a recovery message.
        let float32 = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        XCTAssertTrue(float32.commonFormat == .pcmFormatFloat32, "fixture must be float32")

        XCTAssertThrowsError(try AnalyzerInputResampler(analyzerFormat: float32)) { error in
            XCTAssertEqual(error as? VoiceSessionError, .audioFormatUnavailable)
        }
    }

    func test_init_acceptsTheFormatTheAnalyzerActuallyAsksFor() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        XCTAssertNoThrow(try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat()))
    }

    // MARK: - Format conversion

    func test_convert_downsamplesToTheAnalyzerFormat() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        let inputs = try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))

        XCTAssertFalse(inputs.isEmpty, "48 kHz input must produce analyzer input")
        for input in inputs {
            XCTAssertEqual(
                input.buffer.format.sampleRate, 16_000,
                "every emitted buffer must be in the analyzer's format")
            XCTAssertEqual(input.buffer.format.channelCount, 1)
            XCTAssertEqual(input.buffer.format.commonFormat, .pcmFormatInt16)
        }
    }

    func test_convert_preservesDurationAcrossASteadyFeed() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        // One second of 48 kHz audio in ten 100 ms chunks must land as ~one
        // second of 16 kHz audio. The tolerance covers the resampler's one-off
        // priming latency (~240 frames on the first chunk), which is why this
        // is asserted over a steady feed rather than a single buffer.
        var collected: [AnalyzerInput] = []
        for _ in 0..<10 {
            collected += try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))
        }
        collected += try resampler.flush()

        XCTAssertEqual(
            Double(Self.totalFrames(collected)), 16_000, accuracy: 400,
            "1 s of 48 kHz must resample to ~1 s of 16 kHz, got \(Self.totalFrames(collected))")
    }

    func test_convert_carriesAudioThrough_notSilence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        let inputs = try resampler.convert(Self.tone(rate: 48_000, frames: 9_600))

        let loudest = inputs.map { Self.peak(of: $0.buffer) }.max() ?? 0
        XCTAssertGreaterThan(
            loudest, 0.1,
            "a 0.5-amplitude tone must survive resampling; silence means input was dropped")
    }

    func test_convert_downmixesStereoSourceToMonoAnalyzerFormat() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        let inputs = try resampler.convert(
            Self.tone(rate: 44_100, channels: 2, frames: 4_410))

        XCTAssertFalse(inputs.isEmpty)
        for input in inputs {
            XCTAssertEqual(
                input.buffer.format.channelCount, 1,
                "a stereo tap must be downmixed, not passed through")
        }
    }

    func test_convert_sameFormatStillEmitsABufferWeOwn() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let format = Self.analyzerFormat()
        let resampler = try AnalyzerInputResampler(analyzerFormat: format)
        let source = Self.fill(format, frames: 1_600)

        let inputs = try resampler.convert(source)

        XCTAssertFalse(inputs.isEmpty)
        for input in inputs {
            // The analyzer consumes asynchronously; handing it the caller's
            // buffer would expose it to whoever recycles that buffer.
            XCTAssertFalse(
                input.buffer === source,
                "an identity conversion must still emit our own buffer")
        }
    }

    func test_convert_emptyBuffer_producesNothing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())
        let empty = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            frameCapacity: 4_800)!
        empty.frameLength = 0

        XCTAssertTrue(try resampler.convert(empty).isEmpty)
    }

    // MARK: - Timeline

    func test_convert_stampsAZeroBasedContiguousTimeline() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        var collected: [AnalyzerInput] = []
        for _ in 0..<3 {
            collected += try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))
        }

        XCTAssertFalse(collected.isEmpty)
        // The first buffer must start at zero: segment ids are `seg-%.3f` of the
        // start time, so a non-zero origin would leak engine-start offsets into
        // every id and into the pill's timings.
        XCTAssertEqual(
            CMTimeGetSeconds(collected[0].bufferStartTime ?? .invalid), 0, accuracy: 0.0001,
            "the timeline must be capture-relative, not tap/host time")

        // Each start must be exactly the running sum of frames already emitted.
        var expectedFrame: Int64 = 0
        for input in collected {
            let start = input.bufferStartTime ?? .invalid
            XCTAssertEqual(
                start.value, expectedFrame,
                "buffer starts must be contiguous in analyzer frames")
            XCTAssertEqual(start.timescale, 16_000)
            expectedFrame += Int64(input.buffer.frameLength)
        }
    }

    func test_convert_timelineIsMonotonic() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        var collected: [AnalyzerInput] = []
        for _ in 0..<5 {
            collected += try resampler.convert(Self.tone(rate: 44_100, frames: 2_205))
        }
        collected += try resampler.flush()

        let starts = collected.compactMap { $0.bufferStartTime.map(CMTimeGetSeconds) }
        XCTAssertEqual(starts.count, collected.count, "every input needs a start time")
        XCTAssertEqual(starts, starts.sorted(), "start times must never go backwards")
    }

    // MARK: - Mid-capture format change

    func test_convert_survivesASourceFormatChange_andKeepsTheTimelineRunning() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        // The observed sleep/wake case: the device comes back at a new rate
        // mid-session (44.1 kHz after 48 kHz) without the session restarting.
        let first = try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))
        let second = try resampler.convert(Self.tone(rate: 44_100, frames: 4_410))

        XCTAssertFalse(first.isEmpty, "pre-change audio must convert")
        XCTAssertFalse(second.isEmpty, "post-change audio must convert, not throw")
        for input in first + second {
            XCTAssertEqual(input.buffer.format.sampleRate, 16_000)
        }
        let firstEnd = (first.last?.bufferStartTime?.value ?? 0)
            + Int64(first.last?.buffer.frameLength ?? 0)
        XCTAssertEqual(
            second[0].bufferStartTime?.value, firstEnd,
            "the timeline must continue across the seam, not restart at zero")
    }

    // MARK: - Flush

    func test_flush_beforeAnyInput_producesNothing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())

        // `finishInput` flushes unconditionally, including on a session that was
        // started and stopped without a single buffer arriving.
        XCTAssertTrue(try resampler.flush().isEmpty)
    }

    func test_flush_afterInput_emitsOnlyAnalyzerFormatBuffers() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())
        _ = try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))

        // The tail may legitimately be empty; what must hold is that flushing
        // never throws and never emits a foreign format or an empty buffer.
        for input in try resampler.flush() {
            XCTAssertEqual(input.buffer.format.sampleRate, 16_000)
            XCTAssertEqual(input.buffer.format.commonFormat, .pcmFormatInt16)
            XCTAssertGreaterThan(input.buffer.frameLength, 0, "empty buffers must be dropped")
        }
    }

    func test_flush_isIdempotent() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let resampler = try AnalyzerInputResampler(analyzerFormat: Self.analyzerFormat())
        _ = try resampler.convert(Self.tone(rate: 48_000, frames: 4_800))

        _ = try resampler.flush()
        XCTAssertTrue(
            try resampler.flush().isEmpty,
            "a second flush must not re-emit or hang")
    }
}
