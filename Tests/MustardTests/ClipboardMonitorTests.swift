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
}
