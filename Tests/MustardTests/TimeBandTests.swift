import XCTest
@testable import MustardKit

final class TimeBandTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func test_of_bucketsByHour_atBoundaries() {
        XCTAssertEqual(TimeBand.of(at("2026-06-12T00:00:00Z"), calendar: cal), .morning)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T11:59:00Z"), calendar: cal), .morning)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T12:00:00Z"), calendar: cal), .afternoon)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T16:59:00Z"), calendar: cal), .afternoon)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T17:00:00Z"), calendar: cal), .evening)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T23:30:00Z"), calendar: cal), .evening)
    }

    func test_of_nilForUntimed() {
        XCTAssertNil(TimeBand.of(nil, calendar: cal))
    }
}
