import XCTest
@testable import MustardKit

final class TrustPolicyTests: XCTestCase {
    func test_gatedActionTypes() {
        XCTAssertTrue(TrustPolicy.isGated(actionType: "draft_email"))
        XCTAssertTrue(TrustPolicy.isGated(actionType: "ticket_write"))
        XCTAssertTrue(TrustPolicy.isGated(actionType: "draft_slack"))
        XCTAssertFalse(TrustPolicy.isGated(actionType: "vault_note"))
        XCTAssertFalse(TrustPolicy.isGated(actionType: "create_task"))
    }

    func test_unknownActionType_isGated_neverAutoApproves() {
        XCTAssertTrue(TrustPolicy.isGated(actionType: "draft_emial"))
        XCTAssertTrue(TrustPolicy.isGated(actionType: "send_whatsapp"))
        XCTAssertFalse(TrustPolicy.shouldAutoApprove(actionType: "draft_emial", trust: .autonomous, confidence: 1.0))
    }

    func test_lowConfidence_neverAutoRuns_evenTrusted() {
        XCTAssertFalse(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .trusted, confidence: 0.4))
        XCTAssertTrue(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .trusted, confidence: 0.8))
    }

    func test_confidenceThresholdBoundary() {
        XCTAssertTrue(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .supervised, confidence: 0.7))
        XCTAssertFalse(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .supervised, confidence: 0.69))
    }

    func test_manual_neverAutoApproves() {
        XCTAssertFalse(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .manual))
        XCTAssertFalse(TrustPolicy.shouldAutoAccept(actionType: "vault_note", trust: .manual))
    }

    func test_supervised_autoApprovesNonGated_butDoesNotAutoAccept() {
        XCTAssertTrue(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .supervised))
        XCTAssertFalse(TrustPolicy.shouldAutoAccept(actionType: "vault_note", trust: .supervised))
    }

    func test_trusted_autoApprovesAndAutoAcceptsNonGated() {
        XCTAssertTrue(TrustPolicy.shouldAutoApprove(actionType: "vault_note", trust: .trusted))
        XCTAssertTrue(TrustPolicy.shouldAutoAccept(actionType: "vault_note", trust: .trusted))
    }

    func test_gatedNeverAutoRuns_evenAutonomous() {
        XCTAssertFalse(TrustPolicy.shouldAutoApprove(actionType: "draft_email", trust: .autonomous))
        XCTAssertFalse(TrustPolicy.shouldAutoAccept(actionType: "draft_email", trust: .autonomous))
    }

    func test_delegation_runsAtTrustedPlus_notSupervised() {
        XCTAssertFalse(TrustPolicy.shouldAutoRunDelegation(actionType: "vault_note", trust: .manual, confidence: 0.9))
        XCTAssertFalse(TrustPolicy.shouldAutoRunDelegation(actionType: "vault_note", trust: .supervised, confidence: 0.9))
        XCTAssertTrue(TrustPolicy.shouldAutoRunDelegation(actionType: "vault_note", trust: .trusted, confidence: 0.9))
        XCTAssertTrue(TrustPolicy.shouldAutoRunDelegation(actionType: "vault_note", trust: .autonomous, confidence: 0.9))
    }

    func test_delegation_gatedNeverAutoRuns() {
        XCTAssertFalse(TrustPolicy.shouldAutoRunDelegation(actionType: "draft_email", trust: .autonomous, confidence: 1.0))
    }

    func test_delegation_respectsConfidenceFloor() {
        XCTAssertFalse(TrustPolicy.shouldAutoRunDelegation(actionType: "vault_note", trust: .trusted, confidence: 0.5))
    }
}
