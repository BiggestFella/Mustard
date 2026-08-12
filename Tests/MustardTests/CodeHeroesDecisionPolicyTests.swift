import XCTest
@testable import MustardKit

final class CodeHeroesDecisionPolicyTests: XCTestCase {
    func test_mapsEverySupportedProjectStagePriorityAndStableProjectionFields() throws {
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "dl"), "Digital Licence")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "sales-buddi"), "Sales Buddi")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "sandvik"), "Sandvik")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "code-heroes-internal"), "Code Heroes")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "cross-project"), "Code Heroes")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.stage(for: "needsInput"), .needsInput)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.stage(for: "needsReview"), .needsReview)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "high"), .high)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "medium"), .normal)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "low"), .low)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "urgent"), .urgent)
        XCTAssertEqual(CodeHeroesDecisionPolicy.uid(clusterID: "DL-01"), "codeheroes:decision:DL-01")
        XCTAssertEqual(CodeHeroesDecisionPolicy.source, "codeheroes:decision-triage")
    }

    func test_failsClosedForUnknownMappingAndCreatesBoundedReadOnlyProjection() throws {
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.area(for: "unknown"))
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.stage(for: "inProgress"))
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.priority(for: "normal"))
        let projection = try CodeHeroesDecisionPolicy.projection(for: cluster())
        XCTAssertEqual(projection.owner, .agent)
        XCTAssertNil(projection.actionType)
        XCTAssertNil(projection.delegationMetadata)
        XCTAssertNil(projection.connectedWorkerMetadata)
        XCTAssertTrue(projection.isReadOnly)
        XCTAssertEqual(projection.tags, ["codeheroes", "decision", "project:dl", "triage:needs-human-decision", "human-action"])
        XCTAssertTrue(projection.notes.contains("Question:"))
        XCTAssertTrue(projection.notes.contains("Source IDs:"))
    }

    private func cluster() -> CodeHeroesDecisionQueue.Cluster {
        .init(clusterID: "DL-01", projectID: "dl", title: "A decision", triageState: "needs-human-decision", mustardStage: "needsInput", priority: "high", decisionRequired: true, humanActionRequired: true, question: "Question", nextAction: "Next", whyGrouped: "Why", sourceDecisionIDs: ["DEC-1"])
    }
}
