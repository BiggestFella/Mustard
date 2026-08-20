import XCTest
@testable import MustardKit

final class BridgeListingTests: XCTestCase {
    func test_success_extractsJsonStemsAndDropsNonJson() {
        let listing = BridgeListing.liveJSONUIDs(
            from: .success(["u1.json", "done", "u2.json", "readme.txt", "quarantine"]),
            pathExists: true
        )
        XCTAssertEqual(listing, .listed(["u1", "u2"]))
    }

    func test_success_emptyDir_isListedEmpty() {
        XCTAssertEqual(
            BridgeListing.liveJSONUIDs(from: .success([]), pathExists: true),
            .listed([])
        )
    }

    // BAK-94: a missing results/ or outbox/ dir is indistinguishable from "no live
    // files" — both are safe to treat as empty (export may issue a first order).
    func test_absentPath_isListedEmpty_regardlessOfError() {
        XCTAssertEqual(
            BridgeListing.liveJSONUIDs(from: .failure(CocoaError(.fileReadNoSuchFile)), pathExists: false),
            .listed([])
        )
        XCTAssertEqual(
            BridgeListing.liveJSONUIDs(from: .failure(CocoaError(.fileReadUnknown)), pathExists: false),
            .listed([])
        )
    }

    // BAK-94: a listing error on a path that *does* exist must not collapse to [].
    // Empty would re-introduce BAK-92's double-exec (export re-issues while a live
    // result sits unread).
    func test_listingErrorOnExistingPath_isUnknown() {
        XCTAssertEqual(
            BridgeListing.liveJSONUIDs(from: .failure(CocoaError(.fileReadNoPermission)), pathExists: true),
            .unknown
        )
        XCTAssertEqual(
            BridgeListing.liveJSONUIDs(from: .failure(CocoaError(.fileReadUnknown)), pathExists: true),
            .unknown
        )
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 13) // EACCES
        XCTAssertEqual(BridgeListing.liveJSONUIDs(from: .failure(posix), pathExists: true), .unknown)
    }
}
