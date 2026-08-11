import Foundation

/// Pure decision for BAK-333: a finalized meeting kept its crash-recovery
/// working files forever — a real 23-minute `ready` meeting held
/// `meeting.m4a` (39 MB) + `meeting.partial.caf` (284 MB) + `playback.m4a` +
/// `recovery.json`, ~7x the audio it actually kept, purely because nothing
/// ever cleaned up the Task 3 recovery scratch files once finalization
/// succeeded. `recoverOnLaunch` already guards on `record.status != .ready`,
/// so correctness never depended on these files sticking around — this unit
/// only decides what is now safe to reclaim.
///
/// The decision needs three facts and nothing else: which channels the
/// meeting actually started, which channels' finals are verified on disk,
/// and whether a recovery manifest is still present. It never touches a
/// disk — the coordinator executes the returned list through the validated
/// `MeetingAudioStore` URLs, best-effort.
public enum MeetingWorkingFileCleanup {
    /// Decide which working files are safe to delete right now.
    ///
    /// - A started channel's `.partial.caf` deletes only once THAT channel's
    ///   final `.m4a` is verified to exist — a channel whose final is
    ///   missing keeps its partial: it is the only surviving audio for that
    ///   channel (this is what keeps BAK-332's parity case correct — a
    ///   channel that silently never finalized must not also lose its only
    ///   copy of the audio).
    /// - `recovery.json` deletes only once EVERY started channel's final
    ///   exists. A manifest still tracks safe byte/sample positions for
    ///   whichever channel is missing its final; deleting it early would
    ///   discard the one thing a future recovery attempt for that channel
    ///   could use. An empty `startedSources` (nothing left to track) makes
    ///   this vacuously true, so a manifest with no sources left to account
    ///   for is itself a leftover and is included.
    /// - `playback.m4a` and the finalized `.m4a` files are never returned —
    ///   this unit only ever names crash-recovery scratch files.
    public static func filesToDelete(
        startedSources: Set<MeetingSegmentSource>,
        finalsThatExist: Set<MeetingSegmentSource>,
        hasManifest: Bool
    ) -> [MeetingAudioFile] {
        var result: [MeetingAudioFile] = []
        for source in MeetingSegmentSource.allCases where startedSources.contains(source) {
            if finalsThatExist.contains(source) {
                result.append(source.partialTrack)
            }
        }
        if hasManifest, startedSources.isSubset(of: finalsThatExist) {
            result.append(.recoveryManifest)
        }
        return result
    }
}
