import XCTest
@testable import MustardKit

final class CodeHeroesDecisionPolicyTests: XCTestCase {
    func test_mapsEverySupportedProjectStagePriorityAndStableProjectionFields() throws {
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "dl"), "Digital Licence")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "sales-buddi"), "Sales Buddi")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "code-heroes-internal"), "Code Heroes")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "cross-project"), "Code Heroes")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.area(for: "sandvik"), "Sandvik")
        XCTAssertEqual(try CodeHeroesDecisionPolicy.stage(for: "needsInput"), .needsInput)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.stage(for: "needsReview"), .needsReview)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "high"), .high)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "medium"), .normal)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "low"), .low)
        XCTAssertEqual(try CodeHeroesDecisionPolicy.priority(for: "urgent"), .urgent)
        XCTAssertEqual(CodeHeroesDecisionPolicy.uid(clusterID: "DL-01"), "codeheroes:decision:DL-01")
        XCTAssertEqual(CodeHeroesDecisionPolicy.source, "codeheroes:decision-triage")
        XCTAssertTrue(CodeHeroesDecisionPolicy.isProjection(source: CodeHeroesDecisionPolicy.source))
        XCTAssertFalse(CodeHeroesDecisionPolicy.isProjection(source: "meeting"))
    }

    func test_failsClosedForUnknownMappingAndCreatesBoundedReadOnlyProjection() throws {
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.area(for: "unknown"))
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.stage(for: "inProgress"))
        XCTAssertThrowsError(try CodeHeroesDecisionPolicy.priority(for: "normal"))
        let projection = try CodeHeroesDecisionPolicy.projection(for: cluster())
        XCTAssertEqual(projection.owner, .agent)
        XCTAssertTrue(projection.isReadOnly)
        XCTAssertTrue(CodeHeroesDecisionPolicy.isProjection(projection))
        XCTAssertEqual(projection.uid, "codeheroes:decision:DL-01")
        XCTAssertEqual(projection.sourceDecisionIDs, ["DEC-1"])
        XCTAssertEqual(projection.tags, ["codeheroes", "decision", "project:dl", "triage:needs-human-decision", "human-action"])
        XCTAssertTrue(projection.notes.contains("Question:"))
        XCTAssertTrue(projection.notes.contains("Source IDs:"))

        let noAction = try CodeHeroesDecisionPolicy.projection(for: .init(clusterID: "S-1", projectID: "sandvik", title: "Sandvik", triageState: "needs-evidence", mustardStage: "needsReview", priority: "low", decisionRequired: false, humanActionRequired: false, question: "Q", nextAction: "N", whyGrouped: "W", sourceDecisionIDs: ["DEC-2"]))
        XCTAssertEqual(noAction.area, "Sandvik")
        XCTAssertFalse(noAction.tags.contains("human-action"))
    }

    func test_taskProjectionDetectionUsesTheExactSourceMarker() {
        let projection = MustardTask(title: "Repository decision")
        projection.source = CodeHeroesDecisionPolicy.source

        XCTAssertTrue(CodeHeroesDecisionPolicy.isProjection(projection))

        projection.source = "\(CodeHeroesDecisionPolicy.source):copy"
        XCTAssertFalse(CodeHeroesDecisionPolicy.isProjection(projection))

        projection.source = "manual"
        XCTAssertFalse(CodeHeroesDecisionPolicy.isProjection(projection))
    }

    func test_projectionPresentationProvidesReadOnlyCopyAndSafeLocalSourceAffordances() {
        let projection = MustardTask(title: "Repository decision")
        projection.source = CodeHeroesDecisionPolicy.source
        projection.sourceURL = "/repo/operations/decision-queue.json"
        projection.links = [
            TaskLink(label: "Queue duplicate", url: "/repo/operations/decision-queue.json"),
            TaskLink(label: "Decision", url: "/repo/operations/decisions/open/DEC-1.md"),
            TaskLink(label: "Web", url: "https://example.com/decision"),
            TaskLink(label: "Relative", url: "operations/input.md"),
            TaskLink(label: "File URL", url: "file:///repo/private.md")
        ]

        XCTAssertEqual(CodeHeroesDecisionPresentation.badgeText,
                       "Code Heroes · repository decision · read-only")
        XCTAssertTrue(CodeHeroesDecisionPresentation.readOnlyExplanation.contains("next refresh"))
        XCTAssertEqual(
            CodeHeroesDecisionPresentation.sourceFiles(for: projection),
            [
                .init(label: "Queue", path: "/repo/operations/decision-queue.json"),
                .init(label: "Decision", path: "/repo/operations/decisions/open/DEC-1.md")
            ]
        )

        projection.source = "manual"
        XCTAssertEqual(CodeHeroesDecisionPresentation.sourceFiles(for: projection), [])
    }

    func test_projectionPresentationGatesLocalCompletionAndReopen() {
        let projection = MustardTask(title: "Repository decision")
        projection.source = CodeHeroesDecisionPolicy.source

        XCTAssertFalse(CodeHeroesDecisionPresentation.allowsLocalCompletion(for: projection))

        projection.stage = .done
        XCTAssertFalse(CodeHeroesDecisionPresentation.allowsLocalCompletion(for: projection))

        let ordinary = MustardTask(title: "Ordinary task")
        XCTAssertTrue(CodeHeroesDecisionPresentation.allowsLocalCompletion(for: ordinary))

        ordinary.stage = .done
        XCTAssertTrue(CodeHeroesDecisionPresentation.allowsLocalCompletion(for: ordinary))
    }

    func test_projectionPresentationGatesEveryWeekAndNotchMutationWhilePreservingOrdinaryTasks() {
        let projection = MustardTask(title: "Repository decision")
        projection.source = CodeHeroesDecisionPolicy.source
        let ordinary = MustardTask(title: "Ordinary task")

        for action in CodeHeroesDecisionPresentation.LocalAction.allCases {
            XCTAssertFalse(CodeHeroesDecisionPresentation.allows(action, for: projection),
                           "Projection unexpectedly allowed \(action)")
            XCTAssertTrue(CodeHeroesDecisionPresentation.allows(action, for: ordinary),
                          "Ordinary task unexpectedly denied \(action)")
        }
    }

    private func cluster() -> CodeHeroesDecisionQueue.Cluster {
        .init(clusterID: "DL-01", projectID: "dl", title: "A decision", triageState: "needs-human-decision", mustardStage: "needsInput", priority: "high", decisionRequired: true, humanActionRequired: true, question: "Question", nextAction: "Next", whyGrouped: "Why", sourceDecisionIDs: ["DEC-1"])
    }
}
