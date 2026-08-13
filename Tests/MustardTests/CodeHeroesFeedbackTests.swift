import Foundation
import XCTest
@testable import MustardKit

final class CodeHeroesFeedbackTests: XCTestCase {
    func test_threeComparableSignalsAcrossDistinctClustersCreateOneCandidate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        var events: [CodeHeroesFeedbackEvent] = []

        for index in 1...3 {
            let task = projection(root: root, cluster: "DL-\(index)")
            let result = try CodeHeroesFeedbackRecorder.record(
                task: task,
                signal: .tooNoisy,
                now: now.addingTimeInterval(TimeInterval(index)),
                fileManager: .default
            )
            events.append(result.event)
            if index < 3 { XCTAssertTrue(result.candidates.isEmpty) }
        }

        let candidates = CodeHeroesFeedbackRecorder.aggregate(events, now: now.addingTimeInterval(3))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].signal, .tooNoisy)
        XCTAssertEqual(candidates[0].clusterIDs, ["DL-1", "DL-2", "DL-3"])
        XCTAssertTrue(candidates[0].notes.contains("Approval required"))
        let candidateDir = root.appendingPathComponent("operations/feedback/candidates")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: candidateDir.path).count, 1)
    }

    func test_repeatedSignalOnOneRecordDoesNotReachDistinctRecordThreshold() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let event = CodeHeroesFeedbackEvent(
            eventID: "FEEDBACK-1", signal: .wrongProject, recordedAt: ISO8601DateFormatter().string(from: now),
            clusterID: "DL-1", decisionIDs: ["DEC-1"], projectID: "dl",
            sourceRoutine: CodeHeroesDecisionPolicy.source, actionState: "needsReview", reason: nil
        )
        let candidates = CodeHeroesFeedbackRecorder.aggregate([event, event, event], now: now)
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_feedbackReasonIsBoundedAndNonProjectionIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = projection(root: root, cluster: "DL-1")
        XCTAssertThrowsError(try CodeHeroesFeedbackRecorder.record(
            task: task, signal: .useful, reason: String(repeating: "x", count: 1_001)
        )) { error in
            XCTAssertEqual(error as? CodeHeroesFeedbackError, .invalidReason)
        }
        let ordinary = MustardTask(title: "ordinary")
        XCTAssertThrowsError(try CodeHeroesFeedbackRecorder.record(task: ordinary, signal: .useful)) { error in
            XCTAssertEqual(error as? CodeHeroesFeedbackError, .notProjection)
        }
    }

    private func projection(root: URL, cluster: String) -> MustardTask {
        let queue = root.appendingPathComponent("operations/decisions/triage/queue.json")
        let task = MustardTask(title: "Decision \(cluster)", owner: .agent)
        task.source = CodeHeroesDecisionPolicy.source
        task.stage = .needsReview
        task.sourceURL = queue.path
        task.sourceContext = "digest=sha256:\(String(repeating: "a", count: 64));cluster=\(cluster);source_ids=DEC-\(cluster)"
        task.tags = ["codeheroes", "decision", "project:dl", "human-action"]
        return task
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("operations/decisions/triage", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }
}
