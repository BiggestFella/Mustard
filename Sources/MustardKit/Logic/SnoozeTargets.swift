import Foundation

/// One tested source of truth for triage snooze / schedule target times, used by the
/// desktop console, the mobile detail sheet, the mobile swipe deck, and
/// `AgentService.decide(.scheduled)`. Previously each surface inlined its own copy.
public enum SnoozeTargets {
    /// The next 9:00 strictly after `now` — today if 9am is still ahead, else tomorrow.
    public static func nextNineAM(after now: Date = .now, calendar: Calendar = .current) -> Date {
        if let todayNine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now), todayNine > now {
            return todayNine
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? now
    }

    /// Tomorrow at 9:00, regardless of the current time.
    public static func tomorrow9(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// This afternoon (15:00), but always at least a minute out so a late snooze still hides.
    public static func afternoon(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let target = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now) ?? now
        return max(target, now.addingTimeInterval(60))
    }

    /// This evening (19:00), but always at least a minute out so a late snooze still hides.
    public static func evening(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let target = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now
        return max(target, now.addingTimeInterval(60))
    }
}
