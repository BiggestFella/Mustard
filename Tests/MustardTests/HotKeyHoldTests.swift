import XCTest
@testable import MustardKit

/// Whether a push-to-talk chord is still physically held. Carbon only
/// delivers `kEventHotKeyReleased` reliably while the modifiers are still
/// down, so lifting Control/Option before the key strands the capture in
/// "Listening…" forever with a hot mic. The hold is therefore decided from
/// physical key state, and the rule is pure so both release orders are
/// pinned by tests.
final class HotKeyHoldTests: XCTestCase {
    /// ⌃⌥ — the default capture and dictation chords.
    private let controlOption = UInt32(0x1000 | 0x800)

    private func state(
        key: Bool, control: Bool = false, option: Bool = false,
        shift: Bool = false, command: Bool = false
    ) -> HotKeyChordState {
        HotKeyChordState(
            keyDown: key, control: control, option: option,
            shift: shift, command: command)
    }

    func test_fullChordDown_isHeld() {
        XCTAssertTrue(HotKeyHold.isHeld(
            state(key: true, control: true, option: true),
            carbonModifiers: controlOption))
    }

    func test_keyLiftedFirst_endsTheHold() {
        XCTAssertFalse(
            HotKeyHold.isHeld(
                state(key: false, control: true, option: true),
                carbonModifiers: controlOption),
            "releasing the key while still holding modifiers must end the hold")
    }

    func test_modifierLiftedFirst_endsTheHold() {
        // The order that hangs today: Control goes up before Space.
        XCTAssertFalse(
            HotKeyHold.isHeld(
                state(key: true, control: false, option: true),
                carbonModifiers: controlOption),
            "lifting a required modifier first must end the hold, not strand it")
        XCTAssertFalse(
            HotKeyHold.isHeld(
                state(key: true, control: true, option: false),
                carbonModifiers: controlOption))
    }

    func test_everythingReleased_endsTheHold() {
        XCTAssertFalse(HotKeyHold.isHeld(state(key: false), carbonModifiers: controlOption))
    }

    func test_extraUnrelatedModifier_doesNotEndTheHold() {
        XCTAssertTrue(
            HotKeyHold.isHeld(
                state(key: true, control: true, option: true, shift: true),
                carbonModifiers: controlOption),
            "a stray Shift must not cancel a valid hold")
    }

    func test_chordWithoutModifiers_dependsOnTheKeyAlone() {
        XCTAssertTrue(HotKeyHold.isHeld(state(key: true), carbonModifiers: 0))
        XCTAssertFalse(HotKeyHold.isHeld(state(key: false), carbonModifiers: 0))
    }
}
