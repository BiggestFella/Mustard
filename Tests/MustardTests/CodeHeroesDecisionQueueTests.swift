import XCTest
@testable import MustardKit

final class CodeHeroesDecisionQueueTests: XCTestCase {
    func test_decodesCheckedInQueueContract_andAccountsFor13ClustersAnd22DecisionIDs() throws {
        let queue = try fixture()
        XCTAssertEqual(queue.schemaVersion, 1)
        XCTAssertEqual(queue.reportType, "dream_decision_triage")
        XCTAssertEqual(queue.queue.count, 13)
        let currentIDs = Set(queue.queue.flatMap(\.sourceDecisionIDs)).subtracting(queue.historicalOpenDecisionIDs)
        XCTAssertEqual(currentIDs.count, 22)
        XCTAssertEqual(queue.historicalExclusions.count, 1)
    }

    func test_validationRejectsUnsupportedQueueBoundary() throws {
        var queue = try fixture()
        queue.schemaVersion = 2
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.reportType = "other"
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.readOnly = false
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.decisionStatusMutations = 1
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.mustardImport = "writable"
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.mustardImport = "read-only-but-writable"
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.sourceRunID = "RUN-"
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.sourceReceipt = ""
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
    }

    func test_validationRejectsDuplicateClustersAndQueueSecrets() throws {
        var queue = try fixture()
        queue.queue.append(queue.queue[0])
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
        queue = try fixture(); queue.summary["token"] = .string("ghp_abcdefghijklmnopqrstuvwxyz1234567890")
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
    }

    func test_validationScansHistoricalQueueMetadataForSecrets() throws {
        var queue = try fixture()
        queue.historicalExclusions[0].reason = "-----BEGIN PRIVATE KEY-----"
        XCTAssertThrowsError(try CodeHeroesDecisionQueue.validate(queue))
    }

    func test_clusterValidationSkipsDuplicateSourceIdentity() throws {
        var queue = try fixture()
        queue.queue[1].sourceDecisionIDs = [queue.queue[0].sourceDecisionIDs[0]]
        let result = CodeHeroesDecisionQueue.clusterValidation(for: queue)
        XCTAssertEqual(result.eligible.count, 12)
        XCTAssertEqual(result.findings.single?.reason, "Duplicate source identity")
    }

    func test_clusterValidationSkipsMissingReferencedSource() throws {
        var queue = try fixture()
        queue.queue[0].sourceDecisionIDs = [""]
        let result = CodeHeroesDecisionQueue.clusterValidation(for: queue)
        XCTAssertEqual(result.eligible.count, 12)
        XCTAssertEqual(result.findings.single?.reason, "Missing decision source")
    }

    func test_clusterValidationScansSourceDecisionIDsForSecrets() throws {
        var queue = try fixture()
        queue.queue[0].sourceDecisionIDs = ["DEC-ghp_abcdefghijklmnopqrstuvwxyz1234567890"]
        let result = CodeHeroesDecisionQueue.clusterValidation(for: queue)
        XCTAssertEqual(result.eligible.count, 12)
        XCTAssertEqual(result.findings.single?.reason, "Source-level secret-shaped content")
    }

    func test_clusterFindingsSkipInvalidClustersWhileKeepingValidClustersEligible() throws {
        var queue = try fixture()
        queue.queue[0].projectID = "unknown"
        queue.queue[1].mustardStage = "wrong"
        queue.queue[2].priority = "wrong"
        queue.queue[3].sourceDecisionIDs = ["../DEC-escape", queue.queue[3].sourceDecisionIDs[0]]
        let result = CodeHeroesDecisionQueue.clusterValidation(for: queue)
        XCTAssertEqual(result.eligible.count, 9)
        XCTAssertEqual(result.findings.count, 4)
        XCTAssertTrue(result.findings.allSatisfy { $0.scope == .cluster })
    }

    private func fixture() throws -> CodeHeroesDecisionQueue.Document {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "phase6a-queue", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(CodeHeroesDecisionQueue.Document.self, from: Data(contentsOf: url))
    }
}

private extension Array where Element == CodeHeroesDecisionQueue.Finding {
    var single: Element? { count == 1 ? first : nil }
}
