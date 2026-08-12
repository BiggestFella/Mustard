import XCTest

@testable import MustardKit

/// What a keyDown means while the recorder field is armed. Pure — the view
/// only installs/removes the NSEvent monitor.
final class HotKeyRecorderLogicTests: XCTestCase {
    // NSEvent.ModifierFlags raw bits: shift 1<<17, control 1<<18,
    // option 1<<19, command 1<<20.
    func test_flagMapping_coversAllFourModifiers() {
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 18) | (1 << 19)),
            0x1800)
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 20) | (1 << 17)),
            0x300)
        XCTAssertEqual(HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: 0), 0)
    }

    func test_flagMapping_ignoresCapsLockAndDeviceBits() {
        // Caps lock (1<<16) and device-dependent low bits must not leak in.
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 16) | (1 << 20) | 0xFF),
            0x100)
    }

    func test_escape_cancels() {
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 53, nsEventFlags: 0), .cancel)
        // Even with modifiers held: Esc is always the way out.
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 53, nsEventFlags: 1 << 18), .cancel)
    }

    func test_delete_resetsToDefault() {
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 51, nsEventFlags: 0), .reset)
    }

    func test_anyOtherKey_isAChordAttempt() {
        XCTAssertEqual(
            HotKeyRecorderLogic.outcome(keyCode: 11, nsEventFlags: (1 << 18) | (1 << 19)),
            .capture(keyCode: 11, carbonModifiers: 0x1800))
    }
}
