import XCTest
@testable import MustardKit

/// Meeting-start suggestion scoring and dedupe (Meetings Task 9, BAK-301).
/// Pure and pinned to UTC. A suggestion is data only — nothing here (or on
/// the type) can start capture; recording always goes through the manual
/// consent path.
final class MeetingDetectionTests: XCTestCase {

    /// 2026-07-29T12:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_785_326_400)

    private func event(
        uid: String = "evt-1",
        title: String = "Standup",
        startOffset: TimeInterval = 60,   // one minute from now
        duration: TimeInterval = 1800,
        joinURL: String? = "https://meet.google.com/abc-defg-hij"
    ) -> CalendarEvent {
        CalendarEvent(
            externalId: uid,
            title: title,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + duration),
            joinURL: joinURL)
    }

    private func suggestion(
        events: [CalendarEvent] = [],
        signals: [MeetingAppSignal] = [],
        dismissed: Set<String> = [],
        isRecording: Bool = false
    ) -> MeetingSuggestion? {
        MeetingDetection.suggestion(
            events: events, signals: signals,
            dismissedIdentities: dismissed,
            isRecording: isRecording, now: now)
    }

    // MARK: - Provider parsing

    func test_joinURLs_parseTheirProviders() {
        XCTAssertEqual(MeetingProvider.from(url: "https://meet.google.com/abc"), .googleMeet)
        XCTAssertEqual(MeetingProvider.from(url: "https://us02web.zoom.us/j/123"), .zoom)
        XCTAssertEqual(MeetingProvider.from(url: "https://teams.microsoft.com/l/meetup-join/x"), .teams)
        XCTAssertEqual(MeetingProvider.from(url: "https://app.slack.com/huddle/T123/C456"), .slackHuddle)
        XCTAssertNil(MeetingProvider.from(url: "https://example.com/call"))
        XCTAssertNil(MeetingProvider.from(url: nil))
    }

    // MARK: - Scoring

    func test_meetEventPlusMatchingAppSignal_beatsAppOnly() {
        let matched = suggestion(
            events: [event()],
            signals: [MeetingAppSignal(provider: .googleMeet, detail: "Chrome"),
                      MeetingAppSignal(provider: .zoom, detail: "zoom.us")])

        XCTAssertEqual(matched?.identity, "evt-1", "the corroborated calendar event wins")
        XCTAssertEqual(matched?.provider, .googleMeet)
        XCTAssertEqual(matched?.title, "Standup")
    }

    func test_calendarOnlyEventInsideItsStartWindow_suggests() {
        let result = suggestion(events: [event(joinURL: "https://us02web.zoom.us/j/9")])
        XCTAssertEqual(result?.identity, "evt-1")
        XCTAssertEqual(result?.provider, .zoom)
    }

    func test_appOnlySignal_suggestsWithProviderIdentity() {
        let result = suggestion(signals: [MeetingAppSignal(provider: .teams, detail: "Teams")])
        XCTAssertEqual(result?.provider, .teams)
        XCTAssertNotNil(result?.identity)
        XCTAssertNil(result?.eventUID)
    }

    func test_slackHuddleSignal_suggests() {
        let result = suggestion(signals: [MeetingAppSignal(provider: .slackHuddle, detail: "Slack")])
        XCTAssertEqual(result?.provider, .slackHuddle)
    }

    func test_outsideTheStartWindow_nothingSuggests() {
        XCTAssertNil(
            suggestion(events: [event(startOffset: 3600)]),
            "an event an hour away is not starting")
        XCTAssertNil(
            suggestion(events: [event(startOffset: -7200, duration: 1800)]),
            "an event that already ended is over")
    }

    // MARK: - Dedupe & suppression

    func test_dismissedIdentity_neverSuggestsAgain() {
        XCTAssertNil(suggestion(events: [event()], dismissed: ["evt-1"]))
    }

    func test_whileRecording_nothingEverSuggests() {
        XCTAssertNil(
            suggestion(
                events: [event()],
                signals: [MeetingAppSignal(provider: .googleMeet, detail: nil)],
                isRecording: true),
            "suggestions never appear mid-recording — and nothing can auto-start one")
    }

    func test_eventWithoutUID_fallsBackToProviderPlusStartWindowIdentity() {
        let bare = event(uid: "", joinURL: "https://us02web.zoom.us/j/9")
        let first = suggestion(events: [bare])
        let second = suggestion(events: [bare])

        XCTAssertNotNil(first?.identity)
        XCTAssertFalse(first?.identity.isEmpty ?? true)
        XCTAssertEqual(first?.identity, second?.identity, "the fallback identity is stable for dedupe")
        XCTAssertTrue(first?.identity.contains("zoom") ?? false)
    }

    func test_pinnedUTCWindow_isDeterministic() {
        // Start exactly at the window's early edge (3 minutes before start).
        let edge = event(startOffset: 180)
        XCTAssertNotNil(suggestion(events: [edge]))
        let beyond = event(startOffset: 181)
        XCTAssertNil(suggestion(events: [beyond]))
    }
}
