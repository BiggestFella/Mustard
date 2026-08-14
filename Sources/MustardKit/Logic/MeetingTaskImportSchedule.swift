import Foundation

/// Pure cadence policy for the local meeting-ledger importer. The app's source
/// tick stays frequent for other work; this policy only throttles meeting-file
/// scans to a calm hourly batch.
public enum MeetingTaskImportSchedule {
    public static let defaultInterval: TimeInterval = 60 * 60

    public static func isDue(
        lastImportAt: Date?,
        now: Date,
        interval: TimeInterval = defaultInterval
    ) -> Bool {
        guard let lastImportAt else { return true }
        return now.timeIntervalSince(lastImportAt) >= interval
    }
}
