import XCTest
@testable import MustardKit

/// Deciding when a push-to-talk hold has ended.
///
/// Two hardware facts drive this, both observed on macOS 27:
/// 1. Carbon delivers `kEventHotKeyReleased` reliably ONLY while the chord's
///    modifiers are still down. Lift Control/Option first and it never comes.
/// 2. `CGEventSource.keyState` does NOT report the hotkey's own key as down
///    once Carbon has claimed the chord — it read `key=false` 200ms into a
///    hold the user was still physically holding.
///
/// So the key itself is unobservable, and the MODIFIERS are the only reliable
/// polled signal. Carbon's event covers "key up first"; the modifier poll
/// covers "modifiers up first". Together they cover both orders.
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

    // MARK: - The regression this exists to prevent

    func test_keyReadingAsUp_doesNotEndTheHold() {
        // The exact hardware reading that killed every capture: a real hold,
        // modifiers down, but the consumed key invisible to keyState.
        XCTAssertTrue(
            HotKeyHold.modifiersHeld(
                state(key: false, control: true, option: true),
                carbonModifiers: controlOption),
            "the hotkey's own key is unobservable once Carbon claims it — it must never decide the hold")
    }

    // MARK: - Modifier transitions

    func test_allRequiredModifiersDown_isStillHeld() {
        XCTAssertTrue(HotKeyHold.modifiersHeld(
            state(key: true, control: true, option: true),
            carbonModifiers: controlOption))
    }

    func test_liftingOneRequiredModifier_endsTheHold() {
        XCTAssertFalse(HotKeyHold.modifiersHeld(
            state(key: true, control: false, option: true),
            carbonModifiers: controlOption))
        XCTAssertFalse(HotKeyHold.modifiersHeld(
            state(key: true, control: true, option: false),
            carbonModifiers: controlOption))
    }

    func test_liftingEverything_endsTheHold() {
        XCTAssertFalse(HotKeyHold.modifiersHeld(
            state(key: false), carbonModifiers: controlOption))
    }

    func test_extraUnrelatedModifier_doesNotEndTheHold() {
        XCTAssertTrue(
            HotKeyHold.modifiersHeld(
                state(key: true, control: true, option: true, shift: true),
                carbonModifiers: controlOption),
            "a stray Shift must not cancel a valid hold")
    }

    // MARK: - Chords with no modifiers

    func test_modifierlessChord_neverEndsFromPolling() {
        // Nothing to observe: Carbon's release event is the only signal, so
        // the poll must stay inert rather than ending the hold instantly.
        XCTAssertTrue(HotKeyHold.modifiersHeld(state(key: false), carbonModifiers: 0))
        XCTAssertTrue(HotKeyHold.modifiersHeld(state(key: true), carbonModifiers: 0))
    }
}
