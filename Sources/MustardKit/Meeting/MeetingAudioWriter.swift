import Foundation
import AVFoundation

public enum MeetingAudioWriterError: Error, Equatable {
    /// Only 48 kHz PCM is accepted (the capture unit owns conversion).
    case unsupportedFormat(String)
    /// The writer already finalized; a new recording needs a new writer.
    case writerFinalized
    /// AAC export/mix failed; the partial sources are untouched.
    case exportFailed(String)
}

/// Incrementally persists one meeting's audio (meeting recorder Task 3 —
/// writer portion, BAK-295). 48 kHz PCM buffers append into the
/// `.partial.caf` source tracks with the recovery manifest checkpointed after
/// every durable write — a crash at any moment leaves a discoverable partial
/// meeting. Finalization converts each recorded source to AAC `.m4a`
/// atomically (temp file + rename, never a half-written final), then the mix
/// combines both into `playback.m4a`. Partials are preserved through every
/// failure AND after success — deletion is retention's job (Task 10).
public final class MeetingAudioWriter {
    public static let requiredSampleRate: Double = 48_000

    private let store: MeetingAudioStore
    private let meetingUID: String
    private let startedAt: Date
    private let fileManager: FileManager
    private var trackFiles: [MeetingSegmentSource: AVAudioFile] = [:]
    private var finalized = false

    public init(
        store: MeetingAudioStore,
        meetingUID: String,
        startedAt: Date,
        fileManager: FileManager = .default
    ) throws {
        self.store = store
        self.meetingUID = meetingUID
        self.startedAt = startedAt
        self.fileManager = fileManager
        try store.createMeetingDirectory(forMeetingUID: meetingUID)
    }

    // MARK: - Incremental appends

    /// Append one PCM buffer to a source track and checkpoint the manifest —
    /// the write is durable before the checkpoint claims it is.
    public func append(_ buffer: AVAudioPCMBuffer, to source: MeetingSegmentSource) throws {
        guard !finalized else { throw MeetingAudioWriterError.writerFinalized }
        guard buffer.format.sampleRate == Self.requiredSampleRate else {
            throw MeetingAudioWriterError.unsupportedFormat(
                "expected \(Int(Self.requiredSampleRate)) Hz PCM, got \(Int(buffer.format.sampleRate)) Hz")
        }
        let file = try trackFile(for: source, format: buffer.format)
        try file.write(from: buffer)
        try checkpoint()
    }

    private func trackFile(
        for source: MeetingSegmentSource, format: AVAudioFormat
    ) throws -> AVAudioFile {
        if let existing = trackFiles[source] {
            guard existing.processingFormat.channelCount == format.channelCount else {
                throw MeetingAudioWriterError.unsupportedFormat(
                    "channel count changed mid-recording")
            }
            return existing
        }
        let url = try store.fileURL(for: source.partialTrack, meetingUID: meetingUID)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        trackFiles[source] = file
        return file
    }

    // MARK: - Recovery checkpoints

    /// Rewrite `recovery.json` atomically with the durable positions of every
    /// open source track.
    private func checkpoint() throws {
        let sources = try trackFiles.map { source, file in
            let url = try store.fileURL(for: source.partialTrack, meetingUID: meetingUID)
            let bytes = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return MeetingRecoveryManifest.SourceTrack(
                fileName: source.partialTrack.rawValue,
                safeByteOffset: bytes ?? 0,
                safeSampleOffset: file.length)
        }
        let manifest = MeetingRecoveryManifest(
            meetingUID: meetingUID,
            relativeDirectory: try store.relativeDirectory(forMeetingUID: meetingUID),
            sources: sources.sorted { $0.fileName < $1.fileName },
            startedAt: startedAt,
            lastState: .recording(startedAt: startedAt))
        try manifest.writeAtomically(
            to: store.fileURL(for: .recoveryManifest, meetingUID: meetingUID))
    }

    // MARK: - Finalization

    /// Close the source writers and convert each recorded source to AAC.
    /// Atomic per source: export lands in a temporary sibling and is renamed
    /// into place. Partial `.caf` files are preserved either way.
    public func finalizeSources() async throws {
        finalized = true
        // Closing = releasing; AVAudioFile flushes on dealloc.
        let recorded = Array(trackFiles.keys)
        trackFiles = [:]
        for source in recorded {
            let partial = try store.fileURL(for: source.partialTrack, meetingUID: meetingUID)
            let final = try store.fileURL(for: source.finalTrack, meetingUID: meetingUID)
            try await exportM4A(from: AVURLAsset(url: partial), to: final)
        }
    }

    /// Mix the finalized tracks into `playback.m4a` (both channels summed by
    /// the export). Requires `finalizeSources()` first.
    public func mixPlayback() async throws {
        let composition = AVMutableComposition()
        var added = false
        for source in MeetingSegmentSource.allCases {
            let url = try store.fileURL(for: source.finalTrack, meetingUID: meetingUID)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: .zero)
            added = true
        }
        guard added else {
            throw MeetingAudioWriterError.exportFailed("no finalized sources to mix")
        }
        let playback = try store.fileURL(for: .playback, meetingUID: meetingUID)
        try await exportM4A(from: composition, to: playback)
    }

    // MARK: - Atomic AAC export

    private func exportM4A(from asset: AVAsset, to destination: URL) async throws {
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingAudioWriterError.exportFailed("could not create export session")
        }
        // Temp sibling inside the meeting directory keeps the rename on one
        // volume; the final name only ever holds a complete file.
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent("export-\(UUID().uuidString).m4a.tmp")
        defer { try? fileManager.removeItem(at: temp) }
        do {
            try await session.export(to: temp, as: .m4a)
        } catch {
            throw MeetingAudioWriterError.exportFailed(error.localizedDescription)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temp, to: destination)
    }
}

extension MeetingSegmentSource {
    /// The incrementally written source track for this channel.
    var partialTrack: MeetingAudioFile {
        switch self {
        case .you: .youPartial
        case .meeting: .meetingPartial
        }
    }

    /// The finalized AAC track for this channel.
    var finalTrack: MeetingAudioFile {
        switch self {
        case .you: .you
        case .meeting: .meeting
        }
    }
}
