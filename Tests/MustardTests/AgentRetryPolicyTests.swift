import XCTest
@testable import MustardKit

final class AgentRetryPolicyTests: XCTestCase {
    func test_authenticationPausesGlobally_withoutConsumingTask() {
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .authenticationRequired("401"), action: .vaultNote),
            .pauseRuntime
        )
        // The pause is global regardless of the action being attempted.
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .authenticationRequired("not logged in"), action: .ticket),
            .pauseRuntime
        )
    }

    func test_safeLocalFailureRequeuesWithBackoff() {
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .process("temporary"), action: .vaultNote),
            .retryAfter(seconds: 60)
        )
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .timedOut("slow"), action: .vaultNote),
            .retryAfter(seconds: 60)
        )
    }

    func test_backoffIsBoundedAndCapsAtThreeRetriesThenFails() {
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .process("temporary"), action: .vaultNote, retryCount: 0),
            .retryAfter(seconds: 60)
        )
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .process("temporary"), action: .vaultNote, retryCount: 1),
            .retryAfter(seconds: 300)
        )
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .process("temporary"), action: .vaultNote, retryCount: 2),
            .retryAfter(seconds: 900)
        )
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .process("temporary"), action: .vaultNote, retryCount: 3),
            .fail
        )
    }

    func test_externalCreationWithUnknownResultRequiresReview() {
        // Ticket / email-draft / Slack-draft actions that time out or die mid-process are
        // completion-uncertain — never silently retried, regardless of attempt count.
        for action in [RecommendationAction.ticket, .draftEmail, .draftSlack] {
            XCTAssertEqual(
                AgentRetryPolicy.action(for: .timedOut("timeout"), action: action),
                .completionUncertain
            )
            XCTAssertEqual(
                AgentRetryPolicy.action(for: .process("killed"), action: action, retryCount: 2),
                .completionUncertain
            )
        }
    }

    func test_rateLimitedIsSafeToRetryEvenForExternalActions() {
        // Rate limiting happens before the turn runs, so no external work began.
        XCTAssertEqual(
            AgentRetryPolicy.action(for: .rateLimited("slow down"), action: .ticket),
            .retryAfter(seconds: 60)
        )
    }
}
