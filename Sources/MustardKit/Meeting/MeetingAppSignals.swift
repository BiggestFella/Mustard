#if os(macOS)
import AppKit
import SwiftData
import Observation

/// Live conferencing-app signals (meeting recorder Task 9, BAK-301): a
/// passive scan of running applications by bundle id — no window titles, no
/// extra permissions. Browsers alone are deliberately NOT a signal; browser
/// meetings surface through their calendar event's join URL instead.
public enum MeetingAppSignals {
    static let bundleProviders: [String: MeetingProvider] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "com.tinyspeck.slackmacgap": .slackHuddle,
    ]

    @MainActor
    public static func current() -> [MeetingAppSignal] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  let provider = bundleProviders[bundleID] else { return nil }
            return MeetingAppSignal(provider: provider, detail: app.localizedName)
        }
    }
}

/// Owns the suggestion lifecycle: periodic passive refresh, "Not now"
/// snoozing, and per-event "Don't prompt" dismissal. Data only — starting a
/// recording is the VIEW calling the coordinator's manual consent path.
@MainActor
@Observable
public final class MeetingSuggestionMonitor {
    public private(set) var suggestion: MeetingSuggestion?

    private let events: () -> [CalendarEvent]
    private let signals: () -> [MeetingAppSignal]
    private let isRecording: () -> Bool
    private let now: () -> Date
    private var dismissedForever: Set<String> = []
    private var snoozedUntil: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?

    public init(
        events: @escaping () -> [CalendarEvent],
        signals: @escaping () -> [MeetingAppSignal],
        isRecording: @escaping () -> Bool,
        now: @escaping () -> Date = { .now }
    ) {
        self.events = events
        self.signals = signals
        self.isRecording = isRecording
        self.now = now
    }

    public func refresh() {
        let moment = now()
        let suppressed = dismissedForever.union(
            snoozedUntil.filter { $0.value > moment }.keys)
        suggestion = MeetingDetection.suggestion(
            events: events(),
            signals: signals(),
            dismissedIdentities: suppressed,
            isRecording: isRecording(),
            now: moment)
    }

    /// "Not now": quiet for ten minutes, then eligible again.
    public func snooze(_ dismissed: MeetingSuggestion) {
        snoozedUntil[dismissed.identity] = now().addingTimeInterval(600)
        suggestion = nil
    }

    /// "Don't prompt for this event": gone for good.
    public func dismiss(_ dismissed: MeetingSuggestion) {
        dismissedForever.insert(dismissed.identity)
        suggestion = nil
    }

    /// Passive polling — a scan of running apps + already-fetched calendar
    /// events; nothing here prompts for permissions or starts capture.
    public func startPolling(every seconds: TimeInterval = 30) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
}
#endif
