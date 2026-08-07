import XCTest
@testable import MustardKit

/// Multi-chord Carbon hotkey dispatch. Regression guard: every handler
/// installed on the dispatcher target sees EVERY hotkey event, so a handler
/// that "handles" an event it doesn't own stops propagation and silently
/// kills the other chord (BAK-290 added a second chord and did exactly that
/// — ⌃⌥Space stopped firing because ⌃⌥D's handler swallowed it).
final class HotKeyDispatchTests: XCTestCase {
    private let signature: OSType = 0x4D535444   // 'MSTD'

    func test_ownChord_isHandled() {
        XCTAssertEqual(
            HotKeyDispatch.decide(
                eventSignature: signature, eventID: 1,
                expectedSignature: signature, ownerID: 1),
            .handle)
    }

    func test_anotherInstancesChord_mustFallThrough() {
        // The dictation handler (owner 2) seeing a capture event (id 1).
        XCTAssertEqual(
            HotKeyDispatch.decide(
                eventSignature: signature, eventID: 1,
                expectedSignature: signature, ownerID: 2),
            .passToNextHandler,
            "claiming another chord's event stops propagation and kills that chord")
    }

    func test_capturesHandler_fallsThroughForDictationEvents() {
        XCTAssertEqual(
            HotKeyDispatch.decide(
                eventSignature: signature, eventID: 2,
                expectedSignature: signature, ownerID: 1),
            .passToNextHandler)
    }

    func test_foreignSignature_fallsThrough() {
        XCTAssertEqual(
            HotKeyDispatch.decide(
                eventSignature: 0x4F544852, eventID: 1,
                expectedSignature: signature, ownerID: 1),
            .passToNextHandler)
    }
}
