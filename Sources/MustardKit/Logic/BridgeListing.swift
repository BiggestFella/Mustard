import Foundation

/// Outcome of listing live JSON uids in a bridge folder (`outbox/` or `results/`).
///
/// BAK-94: collapsing every listing failure to `[]` re-opens the BAK-92 double-exec
/// race — export treats "unknown" as "no live files" and re-issues. A missing path
/// is the one failure that *is* empty; a listing error on a path that exists is
/// unknown and the export tick must skip.
public enum BridgeLiveUIDs: Equatable {
    /// Directory listed successfully, or was absent (equivalent to empty).
    case listed(Set<String>)
    /// The path exists but listing failed (permission, not-a-directory, IO).
    /// Do not treat as empty.
    case unknown
}

public enum BridgeListing {
    /// Map a `contentsOfDirectory` outcome to live JSON uids (`<stem>.json` → stem).
    ///
    /// - `pathExists`: whether the listed path itself exists (file or directory).
    ///   Absent → `.listed([])`. Present + listing failed → `.unknown`.
    public static func liveJSONUIDs(
        from contents: Result<[String], Error>,
        pathExists: Bool
    ) -> BridgeLiveUIDs {
        switch contents {
        case .success(let names):
            return .listed(Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }))
        case .failure where !pathExists:
            return .listed([])
        case .failure:
            return .unknown
        }
    }
}
