import XCTest

@testable import MustardKit

/// The nine-action bindings registry (BoardSettings pattern): defaults,
/// round-trip, legacy-key compatibility, resets, malformed fallback.
final class HotKeyBindingsTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "test.hotkeys.\(UUID().uuidString)")!
    }

    func test_defaults_matchShippedChords() {
        let bindings = HotKeyBindings(store: makeStore())
        XCTAssertEqual(bindings.chord(for: .pushToTalk), HotKeyChord(keyCode: 49, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .dictation), HotKeyChord(keyCode: 2, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .rewrite), HotKeyChord(keyCode: 15, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .clips), HotKeyChord(keyCode: 9, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .hover), HotKeyChord(keyCode: 4, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .notch), HotKeyChord(keyCode: 45, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .commandBar), HotKeyChord(keyCode: 40, carbonModifiers: 0x100))
        XCTAssertEqual(bindings.chord(for: .sourceInspector), HotKeyChord(keyCode: 1, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .noteSearch), HotKeyChord(keyCode: 3, carbonModifiers: 0x300))
    }

    func test_globalActions_useTheHistoricUserDefaultsKeys() {
        // These keys predate this feature (PushToTalkHotKey/RewriteHotKey read
        // them at init) — a rename would orphan existing manual overrides.
        XCTAssertEqual(HotKeyAction.pushToTalk.codeKey, "voiceHotKeyCode")
        XCTAssertEqual(HotKeyAction.pushToTalk.modifiersKey, "voiceHotKeyModifiers")
        XCTAssertEqual(HotKeyAction.dictation.codeKey, "dictationHotKeyCode")
        XCTAssertEqual(HotKeyAction.rewrite.codeKey, "rewriteHotKeyCode")
        XCTAssertEqual(HotKeyAction.clips.codeKey, "clipsHotKeyCode")
        XCTAssertEqual(HotKeyAction.clips.modifiersKey, "clipsHotKeyModifiers")
        XCTAssertEqual(HotKeyAction.hover.codeKey, "hotkey.hover.code")
    }

    func test_roundTrip_persistsAsIntPair() {
        let store = makeStore()
        let bindings = HotKeyBindings(store: store)
        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .commandBar)
        XCTAssertEqual(bindings.chord(for: .commandBar), HotKeyChord(keyCode: 11, carbonModifiers: 0x1100))
        // Stored in the exact shape the Carbon hotkey inits read (as? Int).
        XCTAssertEqual(store.object(forKey: "hotkey.commandBar.code") as? Int, 11)
        XCTAssertEqual(store.object(forKey: "hotkey.commandBar.modifiers") as? Int, 0x1100)
    }

    func test_preexistingLegacyOverride_isHonored() {
        let store = makeStore()
        store.set(3, forKey: "voiceHotKeyCode")
        store.set(0x1800, forKey: "voiceHotKeyModifiers")
        XCTAssertEqual(
            HotKeyBindings(store: store).chord(for: .pushToTalk),
            HotKeyChord(keyCode: 3, carbonModifiers: 0x1800))
    }

    func test_malformed_onlyOneKeyPresent_fallsBackToDefault() {
        let store = makeStore()
        store.set(3, forKey: "voiceHotKeyCode")  // modifiers key missing
        XCTAssertEqual(
            HotKeyBindings(store: store).chord(for: .pushToTalk),
            HotKeyAction.pushToTalk.defaultChord)
    }

    func test_reset_removesOverride_resetAllClearsEverything() {
        let store = makeStore()
        let bindings = HotKeyBindings(store: store)
        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .hover)
        bindings.reset(.hover)
        XCTAssertEqual(bindings.chord(for: .hover), HotKeyAction.hover.defaultChord)
        XCTAssertNil(store.object(forKey: "hotkey.hover.code"))

        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .notch)
        bindings.set(HotKeyChord(keyCode: 12, carbonModifiers: 0x1100), for: .rewrite)
        bindings.resetAll()
        XCTAssertEqual(bindings.chord(for: .notch), HotKeyAction.notch.defaultChord)
        XCTAssertEqual(bindings.chord(for: .rewrite), HotKeyAction.rewrite.defaultChord)
    }

    func test_validation_requiresARealModifier() {
        // No modifier at all, and shift-only, both reject: the chord would
        // fire while typing.
        XCTAssertEqual(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0), scope: .inApp),
            .needsModifier)
        XCTAssertEqual(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0x200), scope: .global),
            .needsModifier)
        XCTAssertNil(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0x1000), scope: .global))
    }

    func test_validation_inAppRequiresMappableKey_globalDoesNot() {
        let f1Chord = HotKeyChord(keyCode: 122, carbonModifiers: 0x100)
        XCTAssertEqual(HotKeyValidation.validate(f1Chord, scope: .inApp), .keyNotSupportedInApp)
        XCTAssertNil(HotKeyValidation.validate(f1Chord, scope: .global))
    }
}
