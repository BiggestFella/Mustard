import XCTest
@testable import MustardKit

/// BAK-333: a finalized meeting kept its crash-recovery working files
/// forever — a real 23-minute `ready` meeting held `meeting.m4a` (39 MB) +
/// `meeting.partial.caf` (284 MB) + `playback.m4a` + `recovery.json`, ~7x the
/// audio it actually kept. This pure unit decides, given what a meeting
/// started with and what has actually finalized to disk, exactly which
/// `MeetingAudioFile` cases are now safe to delete. It never touches a disk;
/// the coordinator executes the returned list through the validated
/// `MeetingAudioStore` URLs, best-effort.
final class MeetingWorkingFileCleanupTests: XCTestCase {

    // MARK: - Partial deletion tracks its own source's final

    func test_bothFinalsExist_deletesBothPartialsAndManifest() {
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [.you, .meeting],
            finalsThatExist: [.you, .meeting],
            hasManifest: true)

        XCTAssertEqual(Set(toDelete), [.youPartial, .meetingPartial, .recoveryManifest])
    }

    func test_oneFinalMissing_deletesOnlyTheOtherPartial_keepsManifest() {
        // The mic's final never finalized (BAK-332's exact failure mode) —
        // its partial is the only surviving mic audio and must be kept. The
        // manifest also survives: it still tracks the mic's safe positions,
        // and a future recovery attempt for that channel may need it.
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [.you, .meeting],
            finalsThatExist: [.meeting],
            hasManifest: true)

        XCTAssertEqual(toDelete, [.meetingPartial])
        XCTAssertFalse(toDelete.contains(.recoveryManifest),
                        "manifest deletes only once EVERY started source's final exists")
        XCTAssertFalse(toDelete.contains(.youPartial),
                        "a missing final keeps its partial — it's the only surviving audio")
    }

    func test_noFinalsExist_deletesNothing() {
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [.you, .meeting],
            finalsThatExist: [],
            hasManifest: true)

        XCTAssertTrue(toDelete.isEmpty)
    }

    func test_singleStartedSource_finalExists_deletesItsPartialAndManifest() {
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [.you],
            finalsThatExist: [.you],
            hasManifest: true)

        XCTAssertEqual(Set(toDelete), [.youPartial, .recoveryManifest])
    }

    // MARK: - Manifest deletion is all-or-nothing across started sources

    func test_noManifestOnDisk_neverIncludesManifest_evenWhenEveryFinalExists() {
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [.you, .meeting],
            finalsThatExist: [.you, .meeting],
            hasManifest: false)

        XCTAssertFalse(toDelete.contains(.recoveryManifest))
    }

    func test_manifestOnlyLeftover_noStartedSourcesLeftToTrack_deletesJustTheManifest() {
        // A leftover manifest with nothing left to track (e.g. the started
        // sources are already accounted for elsewhere) is vacuously "every
        // started source's final exists" — nothing but the stale manifest
        // remains to clean up.
        let toDelete = MeetingWorkingFileCleanup.filesToDelete(
            startedSources: [],
            finalsThatExist: [],
            hasManifest: true)

        XCTAssertEqual(toDelete, [.recoveryManifest])
    }

    // MARK: - playback.m4a is never a working file

    func test_playbackNeverInTheDeleteList_acrossEveryScenario() {
        let scenarios: [(Set<MeetingSegmentSource>, Set<MeetingSegmentSource>, Bool)] = [
            ([.you, .meeting], [.you, .meeting], true),
            ([.you, .meeting], [.meeting], true),
            ([.you, .meeting], [], false),
            ([], [], true),
        ]
        for (started, finals, hasManifest) in scenarios {
            let toDelete = MeetingWorkingFileCleanup.filesToDelete(
                startedSources: started, finalsThatExist: finals, hasManifest: hasManifest)
            XCTAssertFalse(toDelete.contains(.playback))
            XCTAssertFalse(toDelete.contains(.you), "a finalized .m4a is never deleted")
            XCTAssertFalse(toDelete.contains(.meeting), "a finalized .m4a is never deleted")
        }
    }
}
