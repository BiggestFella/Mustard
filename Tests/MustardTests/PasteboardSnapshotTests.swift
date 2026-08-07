import XCTest
import AppKit
@testable import MustardKit

/// Lossless pasteboard capture/restore (Dictation Task 3, BAK-289). Uses a
/// private named pasteboard — the user's real clipboard is never touched by
/// tests.
final class PasteboardSnapshotTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("mustard-tests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - The restoration rule

    func test_restores_whenClipboardStillHoldsMustardsWrite() {
        XCTAssertTrue(PasteboardSnapshot.shouldRestore(currentCount: 7, mustardWriteCount: 7))
    }

    func test_neverOverwrites_aNewerExternalChange() {
        XCTAssertFalse(PasteboardSnapshot.shouldRestore(currentCount: 8, mustardWriteCount: 7))
    }

    // MARK: - Capture / restore round trip

    func test_multiTypeItems_roundTripLosslessly() {
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([0x25, 0x50, 0x44, 0x46]), forType: .pdf)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item, second])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        snapshot.restore(to: pasteboard)

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "hello")
        XCTAssertEqual(items.first?.data(forType: .pdf), Data([0x25, 0x50, 0x44, 0x46]))
        XCTAssertEqual(items.last?.string(forType: .string), "https://example.com")
    }

    func test_emptyPasteboard_capturesAndRestoresEmpty() {
        pasteboard.clearContents()

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.setString("transcript", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
    }

    func test_write_returnsTheChangeCountOfMustardsWrite() {
        let count = PasteboardSnapshot.write("transcript", to: pasteboard)

        XCTAssertEqual(count, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
    }
}
