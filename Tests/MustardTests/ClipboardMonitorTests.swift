import XCTest
@testable import MustardKit

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private final class FakePasteboard: PasteboardReading {
        var changeCount = 0
        var candidateToReturn: ClipCandidate?
        var readCount = 0
        func readCandidate() -> ClipCandidate? {
            readCount += 1
            return candidateToReturn
        }
    }

    private func textCandidate(_ text: String) -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [], sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari", isConcealed: false, isTransient: false)
    }

    func testEmitsOnChangeCountBump() {
        let pasteboard = FakePasteboard()
        var received: [ClipCandidate] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { received.append($0) }
        pasteboard.candidateToReturn = textCandidate("hi")

        monitor.pollOnce()   // baseline established at init: changeCount 0 → no emit
        XCTAssertTrue(received.isEmpty)

        pasteboard.changeCount = 1
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["hi"])
    }

    func testNoReadWhenChangeCountIsStable() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }
        monitor.pollOnce()
        monitor.pollOnce()
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testOwnWriteIsSkippedOnce() {
        let pasteboard = FakePasteboard()
        var received: [ClipCandidate] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { received.append($0) }
        pasteboard.candidateToReturn = textCandidate("copied from notch")

        pasteboard.changeCount = 1
        monitor.expectOwnWrite(changeCount: 1)  // notch copy button announces itself
        monitor.pollOnce()
        XCTAssertTrue(received.isEmpty)

        pasteboard.changeCount = 2              // a real copy afterwards still lands
        pasteboard.candidateToReturn = textCandidate("real copy")
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["real copy"])
    }

    /// If the notch's own write (count 1) and a real third-party write (count
    /// 2) land within one poll window, `pollOnce` observes count 1 → 2 in a
    /// single jump and never sees count 1 directly. The exact-match skip
    /// correctly ignores the jump (2 != 1) and emits the real copy — but the
    /// mark for count 1 must not linger in memory forever, and in particular
    /// must never resurface to swallow a later, unrelated observation.
    func testCoalescedOwnWriteDoesNotLeakOrSwallowLaterCopies() {
        let pasteboard = FakePasteboard()
        var received: [ClipCandidate] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { received.append($0) }

        // Own write announced at 1, but a real write coalesces over it —
        // we jump straight from baseline 0 to 2.
        monitor.expectOwnWrite(changeCount: 1)
        pasteboard.changeCount = 2
        pasteboard.candidateToReturn = textCandidate("real copy 1")
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["real copy 1"])

        pasteboard.changeCount = 3
        pasteboard.candidateToReturn = textCandidate("real copy 2")
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["real copy 1", "real copy 2"])

        // Prove the count-1 mark was actually swept (not merely unmatched):
        // if it had leaked, re-observing count 1 later would still be
        // treated as an own write and swallow a real candidate there.
        // (Real NSPasteboard.changeCount never decreases; this only probes
        // that the monitor's internal bookkeeping doesn't retain landmines.)
        pasteboard.changeCount = 1
        pasteboard.candidateToReturn = textCandidate("should not be swallowed")
        monitor.pollOnce()
        XCTAssertEqual(
            received.map(\.text),
            ["real copy 1", "real copy 2", "should not be swallowed"])

        // A mark for a count already passed is inert going forward too.
        monitor.expectOwnWrite(changeCount: 2)  // stale: we're already past 2
        pasteboard.changeCount = 4
        pasteboard.candidateToReturn = textCandidate("real copy 3")
        monitor.pollOnce()
        XCTAssertEqual(
            received.map(\.text),
            ["real copy 1", "real copy 2", "should not be swallowed", "real copy 3"])
    }
}
