import XCTest
@testable import MustardKit

/// Crash-recovery manifest: round-trip encoding + atomic write (meeting
/// recorder, Task 2). All dates pinned; all files live in a per-test temp dir.
final class MeetingRecoveryManifestTests: XCTestCase {
    /// 2026-07-29T00:00:00Z plus a fractional second — proves the encoding
    /// preserves sub-second precision through a round trip.
    private let startDate = Date(timeIntervalSince1970: 1_753_747_200.25)

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManifest(lastState: MeetingRecordingState) -> MeetingRecoveryManifest {
        MeetingRecoveryManifest(
            meetingUID: "1F6A2B3C-0000-4000-8000-000000000001",
            relativeDirectory: "Recordings/1F6A2B3C-0000-4000-8000-000000000001",
            sources: [
                MeetingRecoveryManifest.SourceTrack(
                    fileName: "you.partial.caf", safeByteOffset: 4_096, safeSampleOffset: 48_000),
                MeetingRecoveryManifest.SourceTrack(
                    fileName: "meeting.partial.caf", safeByteOffset: 8_192, safeSampleOffset: 96_000),
            ],
            startedAt: startDate,
            lastState: lastState
        )
    }

    // MARK: - Round-trip encoding

    func test_roundTrip_recordingState_preservesEveryField() throws {
        let manifest = makeManifest(lastState: .recording(startedAt: startDate))
        let data = try manifest.encoded()
        let decoded = try MeetingRecoveryManifest.decoded(from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.startedAt, startDate) // sub-second precision survives
        XCTAssertEqual(decoded.sources.map(\.fileName), ["you.partial.caf", "meeting.partial.caf"])
        XCTAssertEqual(decoded.sources.map(\.safeByteOffset), [4_096, 8_192])
        XCTAssertEqual(decoded.sources.map(\.safeSampleOffset), [48_000, 96_000])
    }

    func test_roundTrip_partialAndFailedStates() throws {
        for state in [MeetingRecordingState.partial("crash"), .failed("disk full"), .paused] {
            let manifest = makeManifest(lastState: state)
            let decoded = try MeetingRecoveryManifest.decoded(from: manifest.encoded())
            XCTAssertEqual(decoded.lastState, state)
        }
    }

    // MARK: - Atomic write

    func test_writeAtomically_createsReadableManifest() throws {
        let url = directory.appendingPathComponent("recovery.json")
        let manifest = makeManifest(lastState: .recording(startedAt: startDate))
        try manifest.writeAtomically(to: url)
        XCTAssertEqual(try MeetingRecoveryManifest.read(from: url), manifest)
    }

    func test_writeAtomically_overwriteReplacesContentWholesale() throws {
        // Each durable audio checkpoint rewrites the manifest; the reader must
        // only ever see a complete old version or a complete new version.
        let url = directory.appendingPathComponent("recovery.json")
        var manifest = makeManifest(lastState: .recording(startedAt: startDate))
        try manifest.writeAtomically(to: url)

        manifest.sources[0].safeByteOffset = 1_048_576
        manifest.sources[0].safeSampleOffset = 480_000
        manifest.lastState = .paused
        try manifest.writeAtomically(to: url)

        let read = try MeetingRecoveryManifest.read(from: url)
        XCTAssertEqual(read, manifest)
        XCTAssertEqual(read.sources[0].safeByteOffset, 1_048_576)
        XCTAssertEqual(read.lastState, .paused)
    }

    func test_writeAtomically_leavesNoTemporaryFilesBehind() throws {
        let url = directory.appendingPathComponent("recovery.json")
        let manifest = makeManifest(lastState: .recording(startedAt: startDate))
        try manifest.writeAtomically(to: url)
        try manifest.writeAtomically(to: url)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["recovery.json"])
    }

    func test_writeAtomically_toMissingDirectory_throwsAndWritesNothing() throws {
        let missing = directory
            .appendingPathComponent("does-not-exist", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let manifest = makeManifest(lastState: .recording(startedAt: startDate))
        XCTAssertThrowsError(try manifest.writeAtomically(to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func test_read_missingFile_throws() {
        let url = directory.appendingPathComponent("recovery.json")
        XCTAssertThrowsError(try MeetingRecoveryManifest.read(from: url))
    }

    func test_read_corruptData_throws() throws {
        let url = directory.appendingPathComponent("recovery.json")
        try Data("not json{{".utf8).write(to: url)
        XCTAssertThrowsError(try MeetingRecoveryManifest.read(from: url))
    }
}
