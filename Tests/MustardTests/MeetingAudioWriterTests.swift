import XCTest
import AVFoundation
@testable import MustardKit

/// The incremental meeting-audio writer (Meetings Task 3 — writer portion,
/// BAK-295): PCM appends into the .partial.caf tracks with the recovery
/// manifest checkpointed after every durable write, atomic per-source AAC
/// finalization, playback mixing, and failure behavior that always preserves
/// the partials. Real files in a temp Recordings root; pinned dates.
final class MeetingAudioWriterTests: XCTestCase {

    private var root: URL!
    private var store: MeetingAudioStore!
    private let startedAt = Date(timeIntervalSince1970: 1_784_714_400)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-writer-tests-\(UUID().uuidString)/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingAudioStore(recordingsRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func buffer(
        frames: AVAudioFrameCount = 4800, rate: Double = 48_000
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for index in 0..<Int(frames) {
                data[0][index] = sinf(Float(index) * 0.02) * 0.1
            }
        }
        return buffer
    }

    private func makeWriter(uid: String = "meeting-1") throws -> MeetingAudioWriter {
        try MeetingAudioWriter(store: store, meetingUID: uid, startedAt: startedAt)
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0) ?? 0
    }

    // MARK: - Incremental appends + checkpoints

    func test_append_writesThePartialTrack_andCheckpointsTheManifest() throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)
        try writer.append(buffer(), to: .you)

        let partial = try store.fileURL(for: .youPartial, meetingUID: "meeting-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertGreaterThan(fileSize(partial), 0)

        let manifest = try MeetingRecoveryManifest.read(
            from: store.fileURL(for: .recoveryManifest, meetingUID: "meeting-1"))
        XCTAssertEqual(manifest.meetingUID, "meeting-1")
        XCTAssertEqual(manifest.relativeDirectory, "Recordings/meeting-1")
        XCTAssertEqual(manifest.startedAt, startedAt)
        let track = try XCTUnwrap(manifest.sources.first { $0.fileName == "you.partial.caf" })
        XCTAssertEqual(track.safeSampleOffset, 9600, "two 4800-frame appends are durable")
        XCTAssertGreaterThan(track.safeByteOffset, 0)
    }

    func test_bothSources_getIndependentTracksAndCheckpoints() throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)
        try writer.append(buffer(frames: 2400), to: .meeting)

        let manifest = try MeetingRecoveryManifest.read(
            from: store.fileURL(for: .recoveryManifest, meetingUID: "meeting-1"))
        XCTAssertEqual(
            manifest.sources.first { $0.fileName == "you.partial.caf" }?.safeSampleOffset, 4800)
        XCTAssertEqual(
            manifest.sources.first { $0.fileName == "meeting.partial.caf" }?.safeSampleOffset, 2400)
    }

    func test_nonFortyEightKilohertzAudio_isRejected() throws {
        let writer = try makeWriter()
        XCTAssertThrowsError(try writer.append(buffer(rate: 44_100), to: .you)) { error in
            guard case MeetingAudioWriterError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }

    // MARK: - Atomic finalization

    func test_finalize_producesPlayableM4A_andPreservesThePartial() async throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)

        try await writer.finalizeSources()

        let finalURL = try store.fileURL(for: .you, meetingUID: "meeting-1")
        let audio = try AVAudioFile(forReading: finalURL)
        XCTAssertGreaterThan(audio.length, 0, "the finalized AAC track is readable audio")
        let partial = try store.fileURL(for: .youPartial, meetingUID: "meeting-1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path),
            "the partial source stays until retention (Task 10) decides otherwise")
        let leftovers = try FileManager.default
            .contentsOfDirectory(at: store.directoryURL(forMeetingUID: "meeting-1"), includingPropertiesForKeys: nil)
            .filter { !MeetingAudioFile.allCases.map(\.rawValue).contains($0.lastPathComponent) }
        XCTAssertTrue(leftovers.isEmpty, "no temporary files survive finalization: \(leftovers)")
    }

    func test_finalize_skipsSourcesThatNeverRecorded() async throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)

        try await writer.finalizeSources()

        let meetingFinal = try store.fileURL(for: .meeting, meetingUID: "meeting-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingFinal.path))
    }

    func test_appendAfterFinalize_throwsWithoutTouchingFiles() async throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)
        try await writer.finalizeSources()
        let partial = try store.fileURL(for: .youPartial, meetingUID: "meeting-1")
        let sizeBefore = fileSize(partial)

        XCTAssertThrowsError(try writer.append(buffer(), to: .you)) { error in
            guard case MeetingAudioWriterError.writerFinalized = error else {
                return XCTFail("expected writerFinalized, got \(error)")
            }
        }
        XCTAssertEqual(fileSize(partial), sizeBefore)
    }

    // MARK: - Playback mix

    func test_mix_producesAPlayableTrackFromBothSources() async throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)
        try writer.append(buffer(), to: .meeting)
        try await writer.finalizeSources()

        try await writer.mixPlayback()

        let playback = try AVAudioFile(
            forReading: store.fileURL(for: .playback, meetingUID: "meeting-1"))
        XCTAssertGreaterThan(playback.length, 0)
    }

    // MARK: - Failure preserves partials (crash-shaped recovery)

    func test_formatMismatchMidRecording_throws_andKeepsTheDurablePartial() throws {
        let writer = try makeWriter()
        try writer.append(buffer(), to: .you)

        XCTAssertThrowsError(try writer.append(buffer(rate: 44_100), to: .you))

        // The durable partial and its manifest survive exactly as checkpointed.
        let partial = try store.fileURL(for: .youPartial, meetingUID: "meeting-1")
        let recovered = try AVAudioFile(forReading: partial)
        XCTAssertEqual(recovered.length, 4800)
        let manifest = try MeetingRecoveryManifest.read(
            from: store.fileURL(for: .recoveryManifest, meetingUID: "meeting-1"))
        XCTAssertEqual(
            manifest.sources.first { $0.fileName == "you.partial.caf" }?.safeSampleOffset, 4800)
    }

    func test_droppedWriter_leavesADiscoverablePartialMeeting() throws {
        var writer: MeetingAudioWriter? = try makeWriter()
        try writer?.append(buffer(), to: .you)
        writer = nil   // crash-shaped: no finalize ever runs

        let manifest = try MeetingRecoveryManifest.read(
            from: store.fileURL(for: .recoveryManifest, meetingUID: "meeting-1"))
        XCTAssertEqual(manifest.sources.first?.safeSampleOffset, 4800)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try store.fileURL(for: .youPartial, meetingUID: "meeting-1").path))
    }
}
