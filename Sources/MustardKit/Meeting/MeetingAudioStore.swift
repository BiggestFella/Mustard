import Foundation

/// Every file a meeting recording may own, exactly as approved in the design:
///
/// ```
/// Application Support/Mustard/Recordings/<meeting-uid>/
///   you.partial.caf        incrementally written microphone source track
///   meeting.partial.caf    incrementally written system-audio source track
///   you.m4a                finalized You track
///   meeting.m4a            finalized Meeting track
///   playback.m4a           mixed playback track
///   recovery.json          crash-recovery manifest (MeetingRecoveryManifest)
/// ```
public enum MeetingAudioFile: String, CaseIterable, Equatable, Sendable {
    case youPartial = "you.partial.caf"
    case meetingPartial = "meeting.partial.caf"
    case you = "you.m4a"
    case meeting = "meeting.m4a"
    case playback = "playback.m4a"
    case recoveryManifest = "recovery.json"

    /// The two incrementally written source tracks that a crash can leave
    /// partial — the files the recovery manifest tracks positions for.
    public static let sourceTracks: [MeetingAudioFile] = [.youPartial, .meetingPartial]
}

public enum MeetingAudioStoreError: Error, Equatable {
    /// The UID would resolve outside — or not exactly one level inside — the
    /// Recordings directory.
    case invalidMeetingUID(String)
}

/// Validated per-meeting audio directory layout (meeting recorder, Task 3 —
/// path portion). Audio never lives in SwiftData; it lives under
/// `Recordings/<meeting-uid>/`, and *every* URL handed out is validated so no
/// UID can escape the Recordings root (deletion later removes whole meeting
/// directories — traversal here would be destructive).
///
/// The root is injected: tests pass a temp directory; the app passes the real
/// `Application Support/Mustard/Recordings` at the call site. The incremental
/// PCM writers (AVFoundation, macOS-only) are deliberately not here.
public struct MeetingAudioStore {
    public let recordingsRoot: URL
    private let fileManager: FileManager

    public init(recordingsRoot: URL, fileManager: FileManager = .default) {
        self.recordingsRoot = recordingsRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    // MARK: - Validation

    /// The per-meeting directory is exactly one path component inside
    /// Recordings. Reject anything else *before* touching URL arithmetic
    /// (empty, ".", "..", separators, NUL), then belt-and-braces verify the
    /// standardized URL still lives inside the root.
    private func validatedUID(_ uid: String) throws -> String {
        guard !uid.isEmpty, uid != ".", uid != "..",
              !uid.contains("/"), !uid.contains("\\"), !uid.contains("\0")
        else { throw MeetingAudioStoreError.invalidMeetingUID(uid) }

        let candidate = recordingsRoot
            .appendingPathComponent(uid, isDirectory: true)
            .standardizedFileURL
        let rootPath = recordingsRoot.path.hasSuffix("/")
            ? recordingsRoot.path
            : recordingsRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              candidate.deletingLastPathComponent().standardizedFileURL.path
                == recordingsRoot.path
        else { throw MeetingAudioStoreError.invalidMeetingUID(uid) }
        return uid
    }

    // MARK: - URLs

    /// `Recordings/<meeting-uid>/` as an absolute URL. Throws
    /// `invalidMeetingUID` rather than ever resolving outside the root.
    public func directoryURL(forMeetingUID uid: String) throws -> URL {
        let valid = try validatedUID(uid)
        return recordingsRoot.appendingPathComponent(valid, isDirectory: true)
    }

    /// The absolute URL of one of the meeting's files (see `MeetingAudioFile`).
    public func fileURL(for file: MeetingAudioFile, meetingUID uid: String) throws -> URL {
        try directoryURL(forMeetingUID: uid)
            .appendingPathComponent(file.rawValue, isDirectory: false)
    }

    /// The validated relative directory persisted in SwiftData and in the
    /// recovery manifest — relative to Mustard's Application Support
    /// container, always exactly `Recordings/<meeting-uid>`.
    public func relativeDirectory(forMeetingUID uid: String) throws -> String {
        "Recordings/\(try validatedUID(uid))"
    }

    // MARK: - Creation

    /// Create (idempotently) and return the exact per-meeting directory.
    @discardableResult
    public func createMeetingDirectory(forMeetingUID uid: String) throws -> URL {
        let url = try directoryURL(forMeetingUID: uid)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
