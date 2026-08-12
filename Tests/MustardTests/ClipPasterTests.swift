import XCTest
@testable import MustardKit

@MainActor
final class ClipPasterTests: XCTestCase {
    func testPasteWritesThenSendsCommandV() async {
        var writes: [String] = []
        var pasted: [pid_t] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
            writeImageToPasteboard: { _ in XCTFail("text paste never writes an image"); return 0 },
            frontmostPID: { 42 },
            sendPaste: { pid in pasted.append(pid); return true },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertTrue(ok)
        XCTAssertEqual(writes, ["hello"])
        XCTAssertEqual(pasted, [42])
    }

    func testOwnWriteIsMarkedSoMonitorSkipsIt() async {
        var marked: [Int] = []
        let paster = ClipPaster(
            writeToPasteboard: { _ in 7 },
            writeImageToPasteboard: { _ in 9 },
            frontmostPID: { 42 },
            sendPaste: { _ in true },
            markOwnWrite: { marked.append($0) })
        _ = await paster.paste(text: "x")
        XCTAssertEqual(marked, [7])
    }

    func testNoFrontmostAppStillCopies() async {
        var writes: [String] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
            writeImageToPasteboard: { _ in 9 },
            frontmostPID: { nil },
            sendPaste: { _ in XCTFail("no paste without a target"); return false },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertFalse(ok)                  // paste didn't happen…
        XCTAssertEqual(writes, ["hello"])   // …but the copy did
    }

    /// Image clips carry bytes, not a payload string — copying one writes the
    /// image and announces the write exactly like the text path.
    func testCopyImageWritesBytesAndMarksOwnWrite() {
        var imageWrites: [Data] = []
        var marked: [Int] = []
        let paster = ClipPaster(
            writeToPasteboard: { _ in XCTFail("image copy never writes text"); return 0 },
            writeImageToPasteboard: { data in imageWrites.append(data); return 9 },
            frontmostPID: { 42 },
            sendPaste: { _ in true },
            markOwnWrite: { marked.append($0) })
        paster.copy(imageData: Data([0x89, 0x50]))
        XCTAssertEqual(imageWrites, [Data([0x89, 0x50])])
        XCTAssertEqual(marked, [9])
    }

    /// An image clip's `payload` is empty. Writing that would silently wipe
    /// the user's clipboard, and pasting it would delete the target's
    /// selection — so an empty payload must never reach the pasteboard.
    func testEmptyTextNeverTouchesThePasteboard() async {
        var touched = false
        let paster = ClipPaster(
            writeToPasteboard: { _ in touched = true; return 7 },
            writeImageToPasteboard: { _ in touched = true; return 9 },
            frontmostPID: { 42 },
            sendPaste: { _ in XCTFail("nothing to paste"); return false },
            markOwnWrite: { _ in touched = true })
        paster.copy(text: "")
        let ok = await paster.paste(text: "")
        XCTAssertFalse(ok)
        XCTAssertFalse(touched)
        paster.copy(imageData: Data())
        XCTAssertFalse(touched)
    }

    /// ⌘V to ourselves would type into the notch's own capture field (or
    /// nothing at all) — refuse it rather than posting a stray keystroke.
    func testPasteIntoMustardItselfIsRefused() async {
        var writes: [String] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
            writeImageToPasteboard: { _ in 9 },
            frontmostPID: { ProcessInfo.processInfo.processIdentifier },
            sendPaste: { _ in XCTFail("never ⌘V into ourselves"); return false },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertFalse(ok)                  // no keystroke…
        XCTAssertEqual(writes, ["hello"])   // …but the clip is on the pasteboard
    }
}
