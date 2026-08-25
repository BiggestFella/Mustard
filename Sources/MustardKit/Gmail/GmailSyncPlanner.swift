import Foundation

/// Decides which listed message ids still need fetching, and maintains the
/// bounded seen-set. Pure — the idempotency layer that keeps a 5-minute poll
/// from re-triaging (and re-paying a claude run for) the same emails, including
/// ones triage judged as noise and dropped.
public enum GmailSyncPlanner {
    /// Keep Gmail's newest-first order, drop already-seen ids, cap the batch.
    /// Leftovers beyond `limit` stay unseen and surface on the next poll.
    public static func newIDs(listed: [String], seen: Set<String>, limit: Int) -> [String] {
        Array(listed.filter { !seen.contains($0) }.prefix(limit))
    }

    /// Append processed ids, keeping at most `cap` of the most recent entries.
    public static func updatedSeen(_ seen: [String], adding: [String], cap: Int) -> [String] {
        var out = seen.filter { !adding.contains($0) } + adding
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }
}
