import Foundation

/// Sizing for the microphone pre-roll buffer (Talkify review, item 1).
///
/// The feed used to build the analyzer session first and install the mic tap
/// last, so everything spoken between key-down and the tap going live was not
/// merely late — it was never recorded. The feed now installs the tap FIRST and
/// buffers into an `AsyncStream`, then starts the session and replays the
/// backlog into it.
///
/// That buffer needs a ceiling. Unbounded, a wedged analyzer start would let
/// audio accumulate in memory for as long as the user held the key; bounded too
/// tightly, a merely slow start would drop the opening words we are trying to
/// save. These constants pin that trade-off where it can be reasoned about and
/// tested, rather than as a bare number inside the audio code.
///
/// When the cap is reached the OLDEST buffered audio is dropped. That is the
/// right degradation: the recent audio is the audio still worth transcribing.
public enum MicrophonePreRoll {
    /// Frames per tap callback — matches the `installTap` buffer size the feed
    /// requests. AVAudioEngine treats this as a hint, so the arithmetic here is
    /// nominal, not a guarantee.
    public static let tapFrameCount = 2_048

    /// How much audio the buffer must cover before we consider it too small.
    /// A cold analyzer start (session construction, asset status check,
    /// `SpeechAnalyzer.start`) is well under a second in the normal case; five
    /// seconds is deliberate slack for a first-run or post-wake start.
    public static let minimumCoveredSeconds: Double = 5

    /// The buffer ceiling, in tap callbacks. ~5.46s at 48kHz, ~5.94s at 44.1kHz.
    ///
    /// This also bounds the backlog during a normal capture, not just the
    /// pre-roll: if the pump ever fell more than this far behind the tap, the
    /// oldest audio would be dropped rather than memory growing without limit.
    /// Five-plus seconds of slack means a healthy capture never comes close.
    public static let maxBufferedChunks = 128

    /// Wall-clock audio held by `chunks` tap callbacks at this sample rate.
    /// Zero for a degenerate format — a device mid-switch can report one, and
    /// this must not divide by zero if it is ever asked about one.
    public static func bufferedSeconds(
        sampleRate: Double,
        framesPerChunk: Int = tapFrameCount,
        chunks: Int = maxBufferedChunks
    ) -> Double {
        guard sampleRate > 0, framesPerChunk > 0, chunks > 0 else { return 0 }
        return Double(chunks) * Double(framesPerChunk) / sampleRate
    }

    /// Tap callbacks needed to cover `seconds`, always rounded up so the target
    /// is genuinely covered rather than very nearly covered.
    public static func chunkCount(
        forSeconds seconds: Double,
        sampleRate: Double,
        framesPerChunk: Int = tapFrameCount
    ) -> Int {
        guard seconds > 0, sampleRate > 0, framesPerChunk > 0 else { return 0 }
        return max(1, Int((seconds * sampleRate / Double(framesPerChunk)).rounded(.up)))
    }
}
