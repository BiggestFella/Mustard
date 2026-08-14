import Foundation

/// Pure staleness gate for harvested meeting tasks (2026-08-14 spec).
///
/// A curated action item is worth a decision while the meeting is still warm.
/// Weeks later it is almost always already done, dead, or superseded — on
/// 2026-08-13 a `dream` pass over the un-integrated back catalogue put 192 such
/// items in front of Leon in 33 minutes, drawn from 44 meetings dated Apr 15 –
/// Jun 4, and the agent spent ~200 turns re-deriving history that had already
/// resolved itself. Nothing older than the window reaches the agent or the
/// approval queue; it imports as reference instead.
///
/// Shares the cutoff arithmetic and the UTC-pinned formatter with
/// `MeetingTaskCleanup` so the import gate and the archive sweep agree on the
/// same boundary — a task the gate holds back is exactly one the sweep prunes.
public enum MeetingTaskFreshness {
    /// The default window, in days. 7 is safe because the upstream routines
    /// (`sync-meeting`, then `dream`) process a meeting within a day of it
    /// happening, so a live action item always arrives well inside it.
    public static let defaultWindowDays = 7

    /// The originating meeting's date, preferring the `src:` slug over the file
    /// the line was harvested from. A Task Ledger line lives in one file but
    /// names its meeting in `src:`, and the ledger's own name says nothing about
    /// when the work was raised. `nil` when neither carries an ISO date.
    public static func meetingDate(srcNote: String?, notePath: String) -> Date? {
        if let srcNote, let date = isoDate(inFileName: srcNote) { return date }
        return isoDate(inFileName: (notePath as NSString).lastPathComponent)
    }

    /// Whether the line's meeting is recent enough to act on.
    ///
    /// **Fails open.** An undated line is treated as fresh: silently downgrading
    /// real work is worse than letting one stale item through, and the archive
    /// sweep is the backstop for anything that slips past.
    public static func isFresh(
        srcNote: String?,
        notePath: String,
        now: Date,
        withinDays days: Int = defaultWindowDays
    ) -> Bool {
        guard let date = meetingDate(srcNote: srcNote, notePath: notePath) else { return true }
        return date >= now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Scans only the file name, never a parent directory — `meetings/2026/05/`
    /// would otherwise date every note in the folder from its path.
    private static func isoDate(inFileName name: String) -> Date? {
        guard let r = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
        else { return nil }
        return isoDay.date(from: String(name[r]))
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
