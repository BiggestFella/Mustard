import Foundation

/// Small on-disk crash-recovery record for one meeting recording (meeting
/// recorder, Task 2). Rewritten atomically after every durable audio
/// checkpoint, so a crash always leaves a discoverable partial meeting: the
/// next launch reads `recovery.json`, trusts only the safe byte/sample
/// positions recorded here, and re-enters the lifecycle via
/// `MeetingRecordingEvent.recover`.
///
/// Foundation-only and pure apart from the explicit read/write helpers — the
/// AVFoundation writers that produce the checkpoints are macOS-only and live
/// elsewhere.
public struct MeetingRecoveryManifest: Codable, Equatable {
    /// One incrementally written source track (`you.partial.caf` /
    /// `meeting.partial.caf`) with the positions known to be durable. Bytes
    /// past `safeByteOffset` may be torn and must be discarded on recovery.
    public struct SourceTrack: Codable, Equatable {
        public var fileName: String
        public var safeByteOffset: Int64
        public var safeSampleOffset: Int64

        public init(fileName: String, safeByteOffset: Int64, safeSampleOffset: Int64) {
            self.fileName = fileName
            self.safeByteOffset = safeByteOffset
            self.safeSampleOffset = safeSampleOffset
        }
    }

    /// Stable UID of the `MeetingRecord` this audio belongs to.
    public var meetingUID: String
    /// The exact per-meeting directory, relative to Mustard's Application
    /// Support container (e.g. `Recordings/<meeting-uid>`) — never absolute,
    /// matching the validated-relative-paths rule for SwiftData.
    public var relativeDirectory: String
    /// The incrementally written source tracks and their safe positions.
    public var sources: [SourceTrack]
    /// When the user confirmed recording started (pinned, injected — never
    /// the ambient clock).
    public var startedAt: Date
    /// The last durable lifecycle state.
    public var lastState: MeetingRecordingState

    public init(
        meetingUID: String,
        relativeDirectory: String,
        sources: [SourceTrack],
        startedAt: Date,
        lastState: MeetingRecordingState
    ) {
        self.meetingUID = meetingUID
        self.relativeDirectory = relativeDirectory
        self.sources = sources
        self.startedAt = startedAt
        self.lastState = lastState
    }

    // MARK: - Encoding

    /// Dates encode as fractional seconds since 1970 — exact round-trip
    /// (ISO-8601 would truncate sub-second precision and shift equality).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> MeetingRecoveryManifest {
        try makeDecoder().decode(MeetingRecoveryManifest.self, from: data)
    }

    // MARK: - Atomic file I/O

    /// Write the manifest so a reader only ever sees a complete old version or
    /// a complete new version: encode fully first (an encoding failure never
    /// touches the file), then hand Foundation the whole blob with `.atomic` —
    /// it writes a sibling temporary file and renames it into place, on both
    /// macOS and (for the pure-logic test suite) Linux. A failure leaves the
    /// previous manifest untouched.
    public func writeAtomically(to url: URL) throws {
        let data = try encoded()
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> MeetingRecoveryManifest {
        try decoded(from: Data(contentsOf: url))
    }
}
