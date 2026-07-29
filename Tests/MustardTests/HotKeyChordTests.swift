import XCTest
@testable import MustardKit

/// Chord formatting for the setup surface (review fix: conflicts must be
/// shown with the failed shortcut, so the shortcut must render readably).
final class HotKeyChordTests: XCTestCase {
    func test_captureChord_rendersControlOptionSpace() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 49, modifiers: 0x1000 | 0x800), "⌃⌥Space")
    }

    func test_dictationChord_rendersControlOptionD() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 2, modifiers: 0x1000 | 0x800), "⌃⌥D")
    }

    func test_unknownKeyCode_fallsBackReadably() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 97, modifiers: 0x100), "⌘key #97")
    }
}
