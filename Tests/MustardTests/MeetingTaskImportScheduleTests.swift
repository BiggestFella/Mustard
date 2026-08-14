import XCTest
@testable import MustardKit

final class MeetingTaskImportScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func test_firstImportIsDueImmediately() {
        XCTAssertTrue(MeetingTaskImportSchedule.isDue(lastImportAt: nil, now: start))
    }

    func test_hourlyImportIsNotDueBeforeTheInterval() {
        let justBefore = start.addingTimeInterval(60 * 60 - 1)

        XCTAssertFalse(MeetingTaskImportSchedule.isDue(lastImportAt: start, now: justBefore))
    }

    func test_hourlyImportIsDueAtTheIntervalBoundary() {
        let boundary = start.addingTimeInterval(60 * 60)

        XCTAssertTrue(MeetingTaskImportSchedule.isDue(lastImportAt: start, now: boundary))
    }

    func test_futureLastImportIsNotDue() {
        XCTAssertFalse(
            MeetingTaskImportSchedule.isDue(
                lastImportAt: start.addingTimeInterval(60),
                now: start
            )
        )
    }
}
