import XCTest

@testable import MustardKit

/// Agent-console triage keys: chord → command matching, when a press may fire,
/// where next/previous land, what approve means per action, and the snooze preset.
final class TriageShortcutsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }
    private var defaults: [HotKeyAction: HotKeyChord] {
        Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultChord) })
    }

    // MARK: chord → command

    func test_command_matchesTheDefaultBareKeys() {
        XCTAssertEqual(
            TriageShortcuts.command(keyCode: 0, carbonModifiers: 0, chords: defaults), .approve)  // A
        XCTAssertEqual(
            TriageShortcuts.command(keyCode: 7, carbonModifiers: 0, chords: defaults), .ignore)  // X
        XCTAssertEqual(
            TriageShortcuts.command(keyCode: 1, carbonModifiers: 0, chords: defaults), .snooze)  // S
        XCTAssertEqual(
            TriageShortcuts.command(keyCode: 38, carbonModifiers: 0, chords: defaults), .next)  // J
        XCTAssertEqual(
            TriageShortcuts.command(keyCode: 40, carbonModifiers: 0, chords: defaults), .previous)  // K
    }

    func test_command_requiresTheModifiersToMatchExactly() {
        // ⌘A (select all) must not read as the bare-A approve key.
        XCTAssertNil(TriageShortcuts.command(keyCode: 0, carbonModifiers: 0x100, chords: defaults))
    }

    func test_command_followsARebind() {
        var chords = defaults
        chords[.triageApprove] = HotKeyChord(keyCode: 14, carbonModifiers: 0x100)  // ⌘E
        XCTAssertEqual(TriageShortcuts.command(keyCode: 14, carbonModifiers: 0x100, chords: chords), .approve)
        XCTAssertNil(TriageShortcuts.command(keyCode: 0, carbonModifiers: 0, chords: chords))
    }

    func test_command_nilForAnUnboundKey() {
        XCTAssertNil(TriageShortcuts.command(keyCode: 17, carbonModifiers: 0, chords: defaults))  // T
    }

    // MARK: gating

    func test_shouldHandle_neverWhileTypingText() {
        // The draft editor, the comment field, the command bar: a bare key is
        // a character there, never a triage decision.
        for command in TriageCommand.allCases {
            XCTAssertFalse(
                TriageShortcuts.shouldHandle(
                    command, isRepeat: false, isEditingText: true, isModalPresented: false))
        }
    }

    func test_shouldHandle_neverWhileASheetIsUp() {
        XCTAssertFalse(
            TriageShortcuts.shouldHandle(
                .approve, isRepeat: false, isEditingText: false, isModalPresented: true))
    }

    func test_shouldHandle_keyRepeatMovesButNeverDecides() {
        // A leaned-on J walks the queue; a leaned-on A must not approve six recs.
        XCTAssertTrue(
            TriageShortcuts.shouldHandle(
                .next, isRepeat: true, isEditingText: false, isModalPresented: false))
        for command in [TriageCommand.approve, .ignore, .snooze] {
            XCTAssertFalse(
                TriageShortcuts.shouldHandle(
                    command, isRepeat: true, isEditingText: false, isModalPresented: false))
        }
    }

    func test_shouldHandle_plainPressPasses() {
        for command in TriageCommand.allCases {
            XCTAssertTrue(
                TriageShortcuts.shouldHandle(
                    command, isRepeat: false, isEditingText: false, isModalPresented: false))
        }
    }

    // MARK: navigation

    func test_visibleOrder_flattensGroupsInRenderOrder() {
        let a = Recommendation(title: "A")
        let b = Recommendation(title: "B")
        let c = Recommendation(title: "C")
        a.sourceItemID = "thread-1"
        b.sourceItemID = "thread-1"
        let order = TriageShortcuts.visibleOrder(SourceGrouping.grouped([a, b, c]))
        XCTAssertEqual(order.map(\.title), ["A", "B", "C"])
    }

    func test_step_movesForwardAndBack() {
        let a = Recommendation(title: "A")
        let b = Recommendation(title: "B")
        XCTAssertTrue(TriageShortcuts.step(from: a, in: [a, b], by: 1) === b)
        XCTAssertTrue(TriageShortcuts.step(from: b, in: [a, b], by: -1) === a)
    }

    func test_step_clampsAtBothEnds() {
        // A triage pass has a start and an end — wrapping would silently
        // re-show a rec you just walked past.
        let a = Recommendation(title: "A")
        let b = Recommendation(title: "B")
        XCTAssertTrue(TriageShortcuts.step(from: b, in: [a, b], by: 1) === b)
        XCTAssertTrue(TriageShortcuts.step(from: a, in: [a, b], by: -1) === a)
    }

    func test_step_fromNothingSelectedTakesTheFirst() {
        let a = Recommendation(title: "A")
        XCTAssertTrue(TriageShortcuts.step(from: nil, in: [a], by: 1) === a)
        XCTAssertTrue(TriageShortcuts.step(from: nil, in: [a], by: -1) === a)
    }

    func test_step_fromARecThatLeftTheQueueTakesTheFirst() {
        let gone = Recommendation(title: "gone")
        let a = Recommendation(title: "A")
        XCTAssertTrue(TriageShortcuts.step(from: gone, in: [a], by: 1) === a)
    }

    func test_step_nilOnAnEmptyQueue() {
        XCTAssertNil(TriageShortcuts.step(from: nil, in: [], by: 1))
    }

    // MARK: approve semantics

    func test_approveOutcome_fyiKeepsInsteadOfRunning() {
        // The FYI card's primary button is "Keep" (file to the log) — the
        // approve key must do that, not run an action the card never offered.
        let rec = Recommendation(title: "FYI")
        rec.action = .fyi
        XCTAssertEqual(TriageShortcuts.approveOutcome(for: rec), .keep)
    }

    func test_approveOutcome_everythingElseRuns() {
        let rec = Recommendation(title: "Draft reply")
        rec.action = .draftEmail
        XCTAssertEqual(TriageShortcuts.approveOutcome(for: rec), .approveAndRun)
    }

    // MARK: snooze preset

    func test_snoozePreset_defaultIsNextDay() {
        XCTAssertEqual(TriageSnoozePreset.default, .tomorrow)
    }

    func test_snoozePreset_targets() {
        let now = date("2026-07-01T10:00:00Z")
        XCTAssertEqual(TriageSnoozePreset.hour.target(from: now, calendar: utc), date("2026-07-01T11:00:00Z"))
        XCTAssertEqual(
            TriageSnoozePreset.afternoon.target(from: now, calendar: utc), date("2026-07-01T15:00:00Z"))
        XCTAssertEqual(
            TriageSnoozePreset.tomorrow.target(from: now, calendar: utc), date("2026-07-02T09:00:00Z"))
    }

    func test_snoozePreset_readsTheStoredChoiceAndFallsBack() {
        let store = UserDefaults(suiteName: "test.triage.\(UUID().uuidString)")!
        XCTAssertEqual(TriageSnoozePreset.current(store: store), .tomorrow)
        store.set("afternoon", forKey: TriageSnoozePreset.storageKey)
        XCTAssertEqual(TriageSnoozePreset.current(store: store), .afternoon)
        store.set("garbage", forKey: TriageSnoozePreset.storageKey)
        XCTAssertEqual(TriageSnoozePreset.current(store: store), .tomorrow)
    }
}
