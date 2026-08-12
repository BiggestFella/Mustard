import XCTest

@testable import MustardKit

/// Chord formatting for the settings surface (review fix: conflicts must be
/// shown with the failed shortcut, so the shortcut must render readably).
final class HotKeyChordTests: XCTestCase {
    func test_captureChord_rendersControlOptionSpace() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 49, modifiers: 0x1000 | 0x800), "⌃⌥Space")
    }

    func test_dictationChord_rendersControlOptionD() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 2, modifiers: 0x1000 | 0x800), "⌃⌥D")
    }

    func test_fullKeyTable_rendersLettersArrowsAndFKeys() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 4, modifiers: 0x100 | 0x200), "⇧⌘H")
        XCTAssertEqual(HotKeyChord.description(keyCode: 126, modifiers: 0x100), "⌘↑")
        XCTAssertEqual(HotKeyChord.description(keyCode: 122, modifiers: 0x1000), "⌃F1")
    }

    func test_unknownKeyCode_fallsBackReadably() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 999, modifiers: 0x100), "⌘key #999")
    }

    func test_chordValue_describesItself_andIsEquatable() {
        let chord = HotKeyChord(keyCode: 49, carbonModifiers: 0x1800)
        XCTAssertEqual(chord.description, "⌃⌥Space")
        XCTAssertEqual(chord, HotKeyChord(keyCode: 49, carbonModifiers: 0x1800))
        XCTAssertNotEqual(chord, HotKeyChord(keyCode: 49, carbonModifiers: 0x100))
    }
}
