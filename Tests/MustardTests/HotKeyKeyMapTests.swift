import SwiftUI
import XCTest

@testable import MustardKit

/// Key-code tables for the hotkey settings surface: display names, SwiftUI
/// KeyEquivalent bridging, and Carbon↔EventModifiers mapping.
final class HotKeyKeyMapTests: XCTestCase {
    func test_displayName_coversLettersDigitsAndSpecials() {
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 4), "H")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 49), "Space")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 18), "1")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 126), "↑")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 122), "F1")
        XCTAssertNil(HotKeyKeyMap.displayName(forKeyCode: 999))
    }

    func test_keyEquivalentCharacter_lettersAreLowercase_spaceIsSpace() {
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 4), "h")
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 49), " ")
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 126), "\u{F700}")
    }

    func test_keyEquivalentCharacter_functionKeysAreNotMappable() {
        // SwiftUI KeyEquivalent has no F-key story we want to rely on; the
        // recorder rejects these for in-app actions.
        XCTAssertNil(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 122))
        XCTAssertNil(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 115))
    }

    func test_eventModifiers_mapsAllFourCarbonMasks() {
        XCTAssertEqual(
            HotKeyKeyMap.eventModifiers(fromCarbon: 0x1000 | 0x800),
            [.control, .option])
        XCTAssertEqual(
            HotKeyKeyMap.eventModifiers(fromCarbon: 0x100 | 0x200),
            [.command, .shift])
        XCTAssertEqual(HotKeyKeyMap.eventModifiers(fromCarbon: 0), [])
    }

    func test_keyboardShortcut_mappableChord_buildsShortcut() {
        let shortcut = HotKeyKeyMap.keyboardShortcut(keyCode: 40, carbonModifiers: 0x100)
        XCTAssertEqual(shortcut, KeyboardShortcut(KeyEquivalent("k"), modifiers: .command))
    }

    func test_keyboardShortcut_unmappableKey_isNil() {
        XCTAssertNil(HotKeyKeyMap.keyboardShortcut(keyCode: 122, carbonModifiers: 0x100))
    }
}
