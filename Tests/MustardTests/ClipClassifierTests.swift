import XCTest
@testable import MustardKit

final class ClipClassifierTests: XCTestCase {
    func testHexColorIsColor() {
        XCTAssertEqual(ClipClassifier.classify(text: "#2D7FF9"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "#fff"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "  #A1B2C3  "), .color)
    }

    func testRGBFunctionIsColor() {
        XCTAssertEqual(ClipClassifier.classify(text: "rgb(45, 127, 249)"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "rgba(45,127,249,0.5)"), .color)
    }

    func testHexLikeButInvalidIsText() {
        XCTAssertEqual(ClipClassifier.classify(text: "#GGGGGG"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "#12345"), .text)  // 5 digits
        XCTAssertEqual(ClipClassifier.classify(text: "#2D7FF9 is our accent"), .text)
    }

    func testHTTPURLIsLink() {
        XCTAssertEqual(ClipClassifier.classify(text: "https://www.supaste.com/"), .link)
        XCTAssertEqual(ClipClassifier.classify(text: "http://localhost:3000/x?y=1"), .link)
    }

    func testNonHTTPSchemesAndProseAreText() {
        XCTAssertEqual(ClipClassifier.classify(text: "ssh deploy@host"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "see https://a.com and https://b.com"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "hello world"), .text)
    }

    func testEmptyAndWhitespaceIsText() {
        XCTAssertEqual(ClipClassifier.classify(text: ""), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "   \n"), .text)
    }

    func testFullwidthHexDigitsAreText() {
        // Unicode Hex_Digit compatibility forms (fullwidth) satisfy
        // Character.isHexDigit but UInt32(_:radix:16) can't parse them.
        XCTAssertEqual(ClipClassifier.classify(text: "#Ａ１Ｂ２Ｃ３"), .text)
    }

    func testMalformedRGBFunctionsAreText() {
        XCTAssertEqual(ClipClassifier.classify(text: "rgb(1,2)"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "rgba(1,2,3,4,5)"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "rgb(a,b,c)"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "rgb(1,2,3"), .text)  // no closing paren
    }

    func testNonHTTPWellFormedURLsAreText() {
        XCTAssertEqual(ClipClassifier.classify(text: "ftp://host/file"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "mailto:leon@codeheroes.com.au"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "file:///tmp/x"), .text)
    }
}
