import XCTest
@testable import MustardKit

@MainActor
final class ClipPasterTests: XCTestCase {
    func testPasteWritesThenSendsCommandV() async {
        var writes: [String] = []
        var pasted: [pid_t] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
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
            frontmostPID: { nil },
            sendPaste: { _ in XCTFail("no paste without a target"); return false },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertFalse(ok)                  // paste didn't happen…
        XCTAssertEqual(writes, ["hello"])   // …but the copy did
    }
}
