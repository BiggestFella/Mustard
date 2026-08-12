import XCTest
@testable import MustardKit

final class ClipStoreRulesTests: XCTestCase {
    private func candidate(
        _ text: String = "hello", bundleID: String? = "com.apple.Safari",
        concealed: Bool = false, transient: Bool = false
    ) -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [],
            sourceBundleID: bundleID, sourceAppName: "Safari",
            isConcealed: concealed, isTransient: transient)
    }

    func testAcceptsOrdinaryText() {
        XCTAssertTrue(ClipStoreRules.shouldCapture(candidate(), latestPayload: nil))
    }

    func testRejectsConcealedAndTransient() {
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate(concealed: true), latestPayload: nil))
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate(transient: true), latestPayload: nil))
    }

    func testRejectsExcludedBundles() {
        for bundle in ClipStoreRules.excludedBundleIDs {
            XCTAssertFalse(
                ClipStoreRules.shouldCapture(candidate(bundleID: bundle), latestPayload: nil),
                bundle)
        }
    }

    func testRejectsConsecutiveDuplicate() {
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate("same"), latestPayload: "same"))
        XCTAssertTrue(ClipStoreRules.shouldCapture(candidate("new"), latestPayload: "old"))
    }

    func testRejectsEmptyCandidate() {
        let empty = ClipCandidate(
            text: "   ", imageData: nil, fileURLs: [], sourceBundleID: nil,
            sourceAppName: nil, isConcealed: false, isTransient: false)
        XCTAssertFalse(ClipStoreRules.shouldCapture(empty, latestPayload: nil))
    }

    func testAcceptsImageOnlyCandidate() {
        let image = ClipCandidate(
            text: nil, imageData: Data([0xFF]), fileURLs: [], sourceBundleID: "com.figma.Desktop",
            sourceAppName: "Figma", isConcealed: false, isTransient: false)
        XCTAssertTrue(ClipStoreRules.shouldCapture(image, latestPayload: nil))
    }

    // MARK: prune

    private struct Row: ClipPrunable {
        let uid: String
        let createdAt: Date
        let pinnedToShelf: Bool
        let isFiled: Bool
    }

    private func rows(_ n: Int, pinned: Set<Int> = [], filed: Set<Int> = []) -> [Row] {
        (0..<n).map { i in
            Row(uid: "c\(i)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                pinnedToShelf: pinned.contains(i), isFiled: filed.contains(i))
        }
    }

    func testNoPruneUnderLimit() {
        XCTAssertEqual(ClipStoreRules.pruneUIDs(rows(200), limit: 200), [])
    }

    func testPrunesOldestUnpinnedBeyondLimit() {
        // 203 unpinned clips → the 3 oldest go.
        XCTAssertEqual(ClipStoreRules.pruneUIDs(rows(203), limit: 200), ["c0", "c1", "c2"])
    }

    func testPinnedAndFiledAreExemptAndDontCountTowardTheLimit() {
        // 202 clips, the two oldest pinned/filed: history size is 200 → no prune.
        XCTAssertEqual(
            ClipStoreRules.pruneUIDs(rows(202, pinned: [0], filed: [1]), limit: 200), [])
        // 203 with oldest pinned: prune skips it and takes the next-oldest.
        XCTAssertEqual(
            ClipStoreRules.pruneUIDs(rows(203, pinned: [0]), limit: 200), ["c1", "c2"])
    }
}
