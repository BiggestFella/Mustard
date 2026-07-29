import Foundation

/// Conferencing providers Mustard recognizes from calendar links or running
/// apps (meeting recorder Task 9, BAK-301).
public enum MeetingProvider: String, Equatable, CaseIterable, Sendable {
    case googleMeet, zoom, teams, slackHuddle

    /// Provider from a conference URL, or nil for anything unrecognized.
    public static func from(url: String?) -> MeetingProvider? {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased() else {
            return nil
        }
        if host == "meet.google.com" { return .googleMeet }
        if host.hasSuffix("zoom.us") { return .zoom }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") {
            return .teams
        }
        if host.hasSuffix("slack.com"), url.contains("/huddle") { return .slackHuddle }
        return nil
    }
}

/// One framework-light signal that a conferencing app is running (the live
/// scan lives in `Meeting/MeetingAppSignals.swift`; tests construct these).
public struct MeetingAppSignal: Equatable, Sendable {
    public var provider: MeetingProvider
    public var detail: String?

    public init(provider: MeetingProvider, detail: String? = nil) {
        self.provider = provider
        self.detail = detail
    }
}

/// A ranked meeting-start suggestion. DATA ONLY, by design: nothing on this
/// type (or in `MeetingDetection`) can start capture — recording always goes
/// through the manual consent path (`MeetingCaptureCoordinator.requestStart`
/// → explicit confirmation).
public struct MeetingSuggestion: Equatable, Sendable {
    /// Dedupe key: the calendar event's UID, else provider + start-window.
    public var identity: String
    public var title: String
    public var provider: MeetingProvider?
    public var eventUID: String?
    public var score: Int
}

/// Pure suggestion scoring: calendar events near their start corroborated by
/// running-app signals rank highest; app-only and calendar-only signals still
/// suggest; dismissed identities and an active recording suppress everything.
public enum MeetingDetection {
    /// How early before an event's start the prompt may appear.
    public static let earlyWindow: TimeInterval = 180

    public static func suggestion(
        events: [CalendarEvent],
        signals: [MeetingAppSignal],
        dismissedIdentities: Set<String>,
        isRecording: Bool,
        now: Date
    ) -> MeetingSuggestion? {
        guard !isRecording else { return nil }   // never mid-recording

        let signalProviders = Set(signals.map(\.provider))
        var candidates: [MeetingSuggestion] = []

        // Calendar events near their start: base score 1, +2 when a running
        // app corroborates the event's provider.
        for event in events {
            guard now >= event.start.addingTimeInterval(-earlyWindow),
                  now <= event.end else { continue }
            let provider = MeetingProvider.from(url: event.joinURL)
            let corroborated = provider.map(signalProviders.contains) ?? false
            candidates.append(MeetingSuggestion(
                identity: identity(for: event, provider: provider),
                title: event.title.isEmpty ? "Meeting" : event.title,
                provider: provider,
                eventUID: event.externalId.isEmpty ? nil : event.externalId,
                score: corroborated ? 3 : 1))
        }

        // App-only signals: something is running right now.
        for signal in signals {
            candidates.append(MeetingSuggestion(
                identity: "app:\(signal.provider.rawValue)",
                title: signal.detail ?? defaultTitle(for: signal.provider),
                provider: signal.provider,
                eventUID: nil,
                score: 1))
        }

        return candidates
            .filter { !dismissedIdentities.contains($0.identity) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Event-backed beats app-only on ties; then stable by identity.
                if (lhs.eventUID != nil) != (rhs.eventUID != nil) {
                    return lhs.eventUID != nil
                }
                return lhs.identity < rhs.identity
            }
            .first
    }

    /// Dedupe identity: the event UID when it has one, else provider plus the
    /// start bucketed to five minutes — stable across refreshes.
    private static func identity(for event: CalendarEvent, provider: MeetingProvider?) -> String {
        if !event.externalId.isEmpty { return event.externalId }
        let bucket = Int(event.start.timeIntervalSince1970 / 300)
        return "\(provider?.rawValue ?? "meeting")@\(bucket)"
    }

    private static func defaultTitle(for provider: MeetingProvider) -> String {
        switch provider {
        case .googleMeet: "Google Meet call"
        case .zoom: "Zoom call"
        case .teams: "Teams call"
        case .slackHuddle: "Slack huddle"
        }
    }
}
