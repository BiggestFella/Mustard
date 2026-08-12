import XCTest

@testable import MustardKit

/// The @Observable bridge between the pure bindings registry and SwiftUI:
/// attempted writes validate + conflict-check, global writes route through
/// the injected applier, resets restore defaults.
@MainActor
final class HotKeyBindingsStoreTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "test.hotkeys.store.\(UUID().uuidString)")!
    }

    func test_attemptSet_valid_savesPersistsAndPublishes() {
        let defaults = makeStore()
        let store = HotKeyBindingsStore(store: defaults)
        let chord = HotKeyChord(keyCode: 11, carbonModifiers: 0x1800)
        XCTAssertEqual(store.attemptSet(chord, for: .commandBar), .saved)
        XCTAssertEqual(store.chord(for: .commandBar), chord)
        XCTAssertEqual(HotKeyBindings(store: defaults).chord(for: .commandBar), chord)
    }

    func test_attemptSet_noModifier_rejectsAndKeepsOldChord() {
        let store = HotKeyBindingsStore(store: makeStore())
        let outcome = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0), for: .commandBar)
        XCTAssertEqual(outcome, .rejected("Add ⌘, ⌃ or ⌥"))
        XCTAssertEqual(store.chord(for: .commandBar), HotKeyAction.commandBar.defaultChord)
    }

    func test_attemptSet_duplicate_rejectsNamingTheOwner() {
        let store = HotKeyBindingsStore(store: makeStore())
        // ⌘⇧H is hover's chord.
        let outcome = store.attemptSet(HotKeyChord(keyCode: 4, carbonModifiers: 0x300), for: .commandBar)
        XCTAssertEqual(outcome, .rejected("Already used by Hover panel"))
    }

    func test_attemptSet_global_routesThroughApplyGlobal_andRecordsStatus() {
        let store = HotKeyBindingsStore(store: makeStore())
        var applied: (action: HotKeyAction, chord: HotKeyChord)?
        store.applyGlobal = { action, chord in
            applied = (action, chord)
            return .conflict(-9878)
        }
        let chord = HotKeyChord(keyCode: 11, carbonModifiers: 0x1800)
        XCTAssertEqual(store.attemptSet(chord, for: .rewrite), .saved)
        XCTAssertEqual(applied?.action, .rewrite)
        XCTAssertEqual(applied?.chord, chord)
        // The chord is saved even when the OS rejects it (spec §6): the row
        // shows the conflict and offers Reset.
        XCTAssertEqual(store.chord(for: .rewrite), chord)
        XCTAssertEqual(store.globalStatus[.rewrite], .conflict(-9878))
    }

    func test_attemptSet_inApp_doesNotTouchApplyGlobal() {
        let store = HotKeyBindingsStore(store: makeStore())
        var applied = false
        store.applyGlobal = { _, _ in applied = true; return .registered }
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .noteSearch)
        XCTAssertFalse(applied)
    }

    func test_reset_restoresDefault_andReappliesGlobal() {
        let defaults = makeStore()
        let store = HotKeyBindingsStore(store: defaults)
        store.applyGlobal = { _, _ in .registered }
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .dictation)
        store.reset(.dictation)
        XCTAssertEqual(store.chord(for: .dictation), HotKeyAction.dictation.defaultChord)
        XCTAssertEqual(store.globalStatus[.dictation], .registered)
        XCTAssertNil(defaults.object(forKey: "dictationHotKeyCode"))
    }

    func test_resetAll_restoresEveryDefault() {
        let store = HotKeyBindingsStore(store: makeStore())
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .hover)
        _ = store.attemptSet(HotKeyChord(keyCode: 12, carbonModifiers: 0x1800), for: .notch)
        store.resetAll()
        for action in HotKeyAction.allCases {
            XCTAssertEqual(store.chord(for: action), action.defaultChord)
        }
    }

    func test_shortcut_forInAppAction_matchesKeyMap() {
        let store = HotKeyBindingsStore(store: makeStore())
        XCTAssertEqual(
            store.shortcut(for: .commandBar),
            HotKeyKeyMap.keyboardShortcut(keyCode: 40, carbonModifiers: 0x100))
    }
}
