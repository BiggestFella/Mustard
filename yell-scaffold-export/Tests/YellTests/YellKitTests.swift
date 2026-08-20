import XCTest
@testable import YellKit

final class YellKitTests: XCTestCase {
    func testProductIdentity() {
        XCTAssertEqual(YellKit.productName, "Yell")
        XCTAssertEqual(YellKit.tagline, "Don't whisper.")
    }
}
