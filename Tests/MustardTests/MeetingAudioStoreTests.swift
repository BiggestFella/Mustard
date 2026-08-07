import XCTest
@testable import MustardKit

/// Validated per-meeting audio directory layout (meeting recorder, Task 3 —
/// pure path-validation portion; the incremental writers are macOS-only and
/// come later). The recordings root is injected so tests use a temp directory.
final class MeetingAudioStoreTests: XCTestCase {
    private var root: URL!
    private var store: MeetingAudioStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audio-store-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingAudioStore(recordingsRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private let uid = "1F6A2B3C-0000-4000-8000-000000000001"

    // MARK: - Traversal rejection

    func test_rejects_parentTraversalUID() {
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "../evil")) { error in
            XCTAssertEqual(error as? MeetingAudioStoreError, .invalidMeetingUID("../evil"))
        }
    }

    func test_rejects_nestedTraversalThatEscapesRecordings() {
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "a/../../b"))
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "a/../.."))
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: ".."))
    }

    func test_rejects_absolutePathUID() {
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "/etc/passwd"))
    }

    func test_rejects_multiComponentUID_evenInsideRecordings() {
        // The layout is exactly Recordings/<meeting-uid>/ — one component.
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "a/b"))
    }

    func test_rejects_emptyDotAndControlUIDs() {
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: ""))
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "."))
        XCTAssertThrowsError(try store.directoryURL(forMeetingUID: "a\0b"))
    }

    func test_rejects_traversal_onEveryDerivedURL() {
        XCTAssertThrowsError(try store.createMeetingDirectory(forMeetingUID: "../evil"))
        XCTAssertThrowsError(try store.fileURL(for: .recoveryManifest, meetingUID: "../evil"))
        XCTAssertThrowsError(try store.relativeDirectory(forMeetingUID: "../evil"))
    }

    func test_rejectedCreate_writesNothingOutsideRecordings() {
        _ = try? store.createMeetingDirectory(forMeetingUID: "../escaped")
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - Exact meeting directory creation

    func test_directoryURL_isExactlyRecordingsSlashUID() throws {
        let url = try store.directoryURL(forMeetingUID: uid)
        XCTAssertEqual(url.standardizedFileURL.path,
                       root.appendingPathComponent(uid).standardizedFileURL.path)
    }

    func test_createMeetingDirectory_createsTheExactDirectory() throws {
        let url = try store.createMeetingDirectory(forMeetingUID: uid)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(url.standardizedFileURL.path,
                       root.appendingPathComponent(uid).standardizedFileURL.path)
    }

    func test_createMeetingDirectory_isIdempotent() throws {
        _ = try store.createMeetingDirectory(forMeetingUID: uid)
        XCTAssertNoThrow(try store.createMeetingDirectory(forMeetingUID: uid))
    }

    func test_relativeDirectory_isRecordingsSlashUID() throws {
        XCTAssertEqual(try store.relativeDirectory(forMeetingUID: uid), "Recordings/\(uid)")
    }

    // MARK: - Source-track and file names

    func test_fileNames_matchTheApprovedLayout() {
        XCTAssertEqual(MeetingAudioFile.youPartial.rawValue, "you.partial.caf")
        XCTAssertEqual(MeetingAudioFile.meetingPartial.rawValue, "meeting.partial.caf")
        XCTAssertEqual(MeetingAudioFile.you.rawValue, "you.m4a")
        XCTAssertEqual(MeetingAudioFile.meeting.rawValue, "meeting.m4a")
        XCTAssertEqual(MeetingAudioFile.playback.rawValue, "playback.m4a")
        XCTAssertEqual(MeetingAudioFile.recoveryManifest.rawValue, "recovery.json")
    }

    func test_sourceTrackFileNames_areTheTwoPartialTracks() {
        XCTAssertEqual(MeetingAudioFile.sourceTracks, [.youPartial, .meetingPartial])
        XCTAssertEqual(MeetingAudioFile.sourceTracks.map(\.rawValue),
                       ["you.partial.caf", "meeting.partial.caf"])
    }

    func test_fileURL_liesInsideTheMeetingDirectory() throws {
        for file in MeetingAudioFile.allCases {
            let url = try store.fileURL(for: file, meetingUID: uid)
            XCTAssertEqual(url.lastPathComponent, file.rawValue)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                           try store.directoryURL(forMeetingUID: uid).standardizedFileURL.path)
        }
    }
}
