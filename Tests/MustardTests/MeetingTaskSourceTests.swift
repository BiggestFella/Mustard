import XCTest
@testable import MustardKit

final class MeetingTaskSourceTests: XCTestCase {
    func test_ledgerRequiresApproval_recordingDoesNot() {
        XCTAssertTrue(MeetingTaskSource.requiresAgentApproval("meeting"))
        XCTAssertFalse(MeetingTaskSource.requiresAgentApproval("meeting-recording"))
        XCTAssertFalse(MeetingTaskSource.requiresAgentApproval("voice"))
        XCTAssertFalse(MeetingTaskSource.requiresAgentApproval(""))
    }
}
