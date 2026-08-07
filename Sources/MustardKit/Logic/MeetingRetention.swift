import Foundation
import SwiftData

/// Retention and deletion for recorded meetings (meeting recorder Task 10,
/// BAK-302). Audio expires after 30 days (pinned meetings are exempt; the
/// transcript, digest, and metadata stay reviewable forever); Delete Meeting
/// moves the exact validated directory to the system Trash FIRST and only
/// then touches SwiftData — a Trash failure preserves everything and the
/// operation is safely retryable.
public enum MeetingRetention {
    public static let defaultDays = 30

    /// Meetings whose audio is past retention right now: unpinned, still
    /// holding audio, and past their deadline (explicit `retentionDeadline`
    /// wins; otherwise end/creation + `days`).
    public static func audioDue(
        _ meetings: [MeetingRecord], now: Date, days: Int = defaultDays
    ) -> [MeetingRecord] {
        meetings.filter { meeting in
            guard !meeting.pinned else { return false }
            guard meeting.youAudioPath != nil
                    || meeting.meetingAudioPath != nil
                    || meeting.playbackAudioPath != nil else { return false }
            let deadline = meeting.retentionDeadline
                ?? (meeting.endedAt ?? meeting.createdAt)
                    .addingTimeInterval(TimeInterval(days) * 86_400)
            return deadline <= now
        }
    }

    /// Remove the meeting's audio directory (validated; idempotent when the
    /// files are already gone) and clear the stored paths. Metadata,
    /// transcript, and digest stay.
    @MainActor
    public static func deleteAudio(
        for meeting: MeetingRecord,
        store: MeetingAudioStore,
        context: ModelContext
    ) throws {
        try store.deleteAudio(forMeetingUID: meeting.uid)
        meeting.youAudioPath = nil
        meeting.meetingAudioPath = nil
        meeting.playbackAudioPath = nil
        meeting.retentionDeadline = nil
        try? context.save()
    }

    /// Move the meeting's directory to the system Trash, then delete the
    /// record (cascading segments/proposals). Trash FIRST — a failure keeps
    /// metadata and paths intact for a retry.
    @MainActor
    public static func deleteMeeting(
        _ meeting: MeetingRecord,
        store: MeetingAudioStore,
        context: ModelContext,
        trash: (URL) throws -> Void
    ) throws {
        try store.trashMeetingDirectory(forMeetingUID: meeting.uid, trash: trash)
        context.delete(meeting)
        try? context.save()
    }

    /// The launch sweep: clear audio for everything past retention.
    @MainActor
    public static func sweep(
        meetings: [MeetingRecord],
        store: MeetingAudioStore,
        context: ModelContext,
        now: Date
    ) {
        for due in audioDue(meetings, now: now) {
            try? deleteAudio(for: due, store: store, context: context)
        }
    }
}
