import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Resamples caller PCM buffers into the format `SpeechAnalyzer` asked for and
/// wraps each one as an `AnalyzerInput` on a zero-based media timeline.
///
/// **Why this exists.** The macOS 27 SDK shipped `Speech.AnalyzerInputConverter`,
/// which did exactly this. The macOS 28 SDK removed it, and the Speech framework
/// now exposes no conversion API at all — only `AnalyzerInput(buffer:
/// bufferStartTime:)` and `SpeechAnalyzer.bestAvailableAudioFormat`. Feeding the
/// analyzer is the caller's job again, so this is the hand-rolled equivalent.
/// It deliberately uses nothing newer than `AVAudioConverter` (macOS 10.11), so
/// it compiles against both the 27 and 28 SDKs and the repo stops depending on
/// which Xcode happens to be selected.
///
/// `AVAudioConverter`'s pull-based `convert(to:error:withInputFrom:)` is the only
/// variant that can resample — `convert(to:from:)` is documented as "a conversion
/// which does not involve codecs or sample rate conversion" — and resampling is
/// the whole point here: the analyzer's preferred format is typically 16 kHz
/// against a 44.1/48 kHz microphone.
///
/// Every emitted buffer is one this type allocated, including when the source
/// format already matches the analyzer's: an identity conversion still routes
/// through the converter rather than forwarding the caller's buffer, so the
/// analyzer can never be handed audio somebody else might recycle.
@available(macOS 26.0, *)
final class AnalyzerInputResampler {
    /// The format `SpeechAnalyzer.bestAvailableAudioFormat` chose.
    let analyzerFormat: AVAudioFormat

    /// Built lazily on the first buffer and rebuilt whenever the source format
    /// changes mid-capture — a device swap or a sleep/wake format change hands
    /// the tap a different format without restarting the session. Rebuilding
    /// discards whatever tail was still inside the old converter (a few ms at
    /// the seam); the alternative is refusing audio outright.
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Start frame of the next emitted buffer, counted in analyzer frames.
    ///
    /// The analyzer wants a monotonic media timeline, and it has to be
    /// capture-relative: `AppleSpeechSession.segment` derives both a segment's
    /// `startSeconds` and its id (`seg-%.3f`) from the result's range, so an
    /// origin anywhere other than zero would make every segment id an offset
    /// from engine start. The caller's `AVAudioTime` is a tap/host timebase
    /// whose origin is unrelated to this session, so it is deliberately not
    /// used; counting what we actually emit is exact, monotonic by
    /// construction, identical for the mic and meeting feeds, and survives a
    /// mid-capture format change.
    private var nextStartFrame: AVAudioFramePosition = 0

    /// Extra output capacity per call. Without slack a snug buffer fills before
    /// the converter has drained its input and the remainder waits inside the
    /// converter until the next `convert`, so latency creeps. `drain` loops when
    /// that happens anyway, which keeps the slack a tuning value rather than a
    /// correctness one.
    private static let outputSlackFrames: AVAudioFrameCount = 1_024

    /// Output capacity for `flush`. A resampler tail is a handful of frames;
    /// this is ~256 ms at 16 kHz and `drain` loops if it somehow is not enough.
    private static let flushCapacityFrames: AVAudioFrameCount = 4_096

    /// Backstop so a converter that never reports `inputRanDry`/`endOfStream`
    /// cannot spin forever holding the session's actor.
    private static let maxDrainRounds = 16

    /// - Throws: `VoiceSessionError.audioFormatUnavailable` if the analyzer asked
    ///   for a floating-point format. `AnalyzerInput.init(buffer:…)` traps —
    ///   `EXC_BREAKPOINT` inside `AnalyzerInput.data(from:)`, not a catchable
    ///   error — for any float32/float64 PCM buffer, measured on macOS 27.0
    ///   (26A5388g) against both the 27 and 28 SDKs. In practice this never
    ///   fires: `SpeechAnalyzer.bestAvailableAudioFormat` reports 16 kHz mono
    ///   **Int16** here, which is exactly what `AnalyzerInput` accepts. It is a
    ///   guard against turning a future SDK change into a hard crash inside the
    ///   audio path, which is the failure mode this file's neighbours already
    ///   fight (see `VoiceSessionError.audioEngineFailure`). If a later macOS
    ///   does start reporting a float analyzer format *and* accepts it, relax
    ///   this check rather than converting to Int16 behind the analyzer's back.
    init(analyzerFormat: AVAudioFormat) throws {
        switch analyzerFormat.commonFormat {
        case .pcmFormatFloat32, .pcmFormatFloat64:
            throw VoiceSessionError.audioFormatUnavailable
        default:
            break
        }
        self.analyzerFormat = analyzerFormat
    }

    /// Converts one caller buffer into analyzer inputs. Returns an empty array
    /// for an empty buffer, and may return more than one input when a single
    /// call produced more output than one buffer could hold.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        guard buffer.frameLength > 0 else { return [] }
        let sourceRate = buffer.format.sampleRate
        let analyzerRate = analyzerFormat.sampleRate
        guard sourceRate > 0, analyzerRate > 0 else {
            throw VoiceSessionError.audioFormatUnavailable
        }

        let converter = try resamplingConverter(for: buffer.format)
        let ratio = analyzerRate / sourceRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            + Self.outputSlackFrames
        return try drain(converter, capacity: capacity, feeding: buffer)
    }

    /// Drains the converter's internal tail at end of input. Safe to call when
    /// nothing was ever appended.
    func flush() throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        return try drain(converter, capacity: Self.flushCapacityFrames, feeding: nil)
    }

    // MARK: - Conversion

    private func resamplingConverter(for source: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, let sourceFormat, sourceFormat == source { return converter }
        guard let made = AVAudioConverter(from: source, to: analyzerFormat) else {
            throw VoiceSessionError.audioFormatUnavailable
        }
        converter = made
        sourceFormat = source
        return made
    }

    /// Pulls output until the converter runs out of material. `feeding: nil`
    /// declares end of stream, which is what makes the resampler emit its tail.
    private func drain(
        _ converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        feeding source: AVAudioPCMBuffer?
    ) throws -> [AnalyzerInput] {
        let feed = InputFeed(source)
        var inputs: [AnalyzerInput] = []

        for _ in 0..<Self.maxDrainRounds {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                throw VoiceSessionError.audioFormatUnavailable
            }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                feed.next(inputStatus)
            }
            if output.frameLength > 0 { inputs.append(emit(output)) }

            switch status {
            case .haveData:
                // The output buffer filled before the converter ran dry — go
                // round again rather than stranding converted frames inside
                // the converter until the next append.
                continue
            case .inputRanDry, .endOfStream:
                return inputs
            case .error:
                throw failure ?? VoiceSessionError.audioFormatUnavailable
            @unknown default:
                return inputs
            }
        }
        return inputs
    }

    /// Stamps a converted buffer onto the running timeline and advances it.
    private func emit(_ buffer: AVAudioPCMBuffer) -> AnalyzerInput {
        let timescale = CMTimeScale(analyzerFormat.sampleRate.rounded())
        let start = CMTime(value: nextStartFrame, timescale: timescale)
        nextStartFrame += AVAudioFramePosition(buffer.frameLength)
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }
}

/// Hands the converter its one input buffer, then reports why there is no more.
///
/// A reference type because `AVAudioConverterInputBlock` is `@Sendable` and so
/// cannot capture a mutable local. `@unchecked Sendable` is honest here rather
/// than a papering-over: `convert(to:error:withInputFrom:)` invokes the block
/// synchronously on the calling thread before it returns, so the box is never
/// touched from two threads, and each box is scoped to a single `drain` call.
@available(macOS 26.0, *)
private final class InputFeed: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?
    /// `nil` input means the caller is flushing, so exhaustion is end of
    /// stream (drain the tail) rather than "nothing right now" (keep the
    /// resampler primed for the next append).
    private let endsStream: Bool

    init(_ buffer: AVAudioPCMBuffer?) {
        self.pending = buffer
        self.endsStream = buffer == nil
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let pending {
            self.pending = nil
            status.pointee = .haveData
            return pending
        }
        status.pointee = endsStream ? .endOfStream : .noDataNow
        return nil
    }
}
