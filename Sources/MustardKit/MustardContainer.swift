import Foundation
import SwiftData

/// Builds the app's persistent ModelContainer at a Mustard-owned location
/// (avoids colliding with other unsandboxed apps' default.store).
public enum MustardContainer {
    public static func make() -> ModelContainer {
        let dir = URL.applicationSupportDirectory.appending(path: "Mustard", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: dir.appending(path: "mustard.store"))
        do {
            let container = try ModelContainer(
                for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
                AgentRun.self, AgentMessage.self, AgentDraft.self, CalendarEvent.self, NoteIndexEntry.self,
                MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
                configurations: config
            )
            // One-time backfill of the stage model from legacy status (BAK-75).
            // A fresh context avoids the main-actor isolation of `mainContext`.
            let migration = ModelContext(container)
            BoardMigration.backfill(migration)
            // Re-place any scheduled task stranded in the Inbox (BAK-246) — after the
            // stage backfill so it reads migrated stages, not legacy status.
            BoardMigration.normalizeScheduledPlacement(migration)
            try? migration.save()
            return container
        } catch {
            fatalError("Could not open Mustard store: \(error)")
        }
    }
}
