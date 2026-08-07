import Foundation
import SwiftData

/// One-time migration of pre-stage tasks onto `TaskStage`. The pure `stage(...)`
/// mapping is unit-tested; `backfill` applies it across the store at launch.
public enum BoardMigration {
    /// Map a pre-stage task to a `TaskStage`. Accepts the deliberate data loss agreed
    /// in the spec: `someday` collapses into `inbox`; any open agent-owned task lands
    /// in `queued` (re-triage from there).
    public static func stage(legacyStatus: TaskStatus, scheduledAt: Date?, owner: TaskOwner) -> TaskStage {
        if owner == .agent { return legacyStatus == .done ? .done : .queued }
        switch legacyStatus {
        case .inbox: return .inbox
        case .someday: return .inbox
        case .planned: return scheduledAt != nil ? .scheduled : .planned
        case .inProgress: return .inProgress
        case .done: return .done
        }
    }

    /// Backfill `stage` for any task not yet migrated. Idempotent: the `migratedStage`
    /// flag means re-running (or running on an already-migrated store) is a no-op.
    public static func backfill(_ context: ModelContext) {
        guard let tasks = try? context.fetch(FetchDescriptor<MustardTask>()) else { return }
        for t in tasks where !t.migratedStage {
            let legacy = TaskStatus(rawValue: t.statusRaw) ?? .inbox
            t.stage = stage(legacyStatus: legacy, scheduledAt: t.scheduledAt, owner: t.owner)
            t.migratedStage = true
        }
    }

    /// One-time repair for stores written before BAK-246: any `.inbox` task that
    /// already carries a `scheduledAt` is re-placed by the canonical invariant
    /// (`PersonalBoard.normalizePlacement`) — timed → `.scheduled`, otherwise
    /// `.planned` — so scheduled cards no longer strand in the Inbox column. Runs at
    /// launch after `backfill`. Idempotent and self-correcting: once a task is off the
    /// inbox it is never revisited, and unscheduled inbox tasks stay untriaged, so no
    /// per-row flag is needed (unlike the stage backfill, this can't clobber later
    /// edits — it only ever moves a scheduled task out of the inbox).
    public static func normalizeScheduledPlacement(_ context: ModelContext) {
        guard let tasks = try? context.fetch(FetchDescriptor<MustardTask>()) else { return }
        for t in tasks { PersonalBoard.normalizePlacement(t) }
    }
}
