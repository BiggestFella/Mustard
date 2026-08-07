import Foundation
import XCTest
@testable import MustardKit

final class AgentTurnContractTests: XCTestCase {
    func test_decodesNeedsInput() throws {
        let json = #"{"outcome":"needs_input","message":"I need the version","questions":["Which version?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

        let result = try AgentTurnContract.decode(json)

        XCTAssertEqual(result.outcome, .needsInput)
        XCTAssertEqual(result.questions, ["Which version?"])
    }

    func test_decodesCompletedArtifact() throws {
        let json = #"{"outcome":"completed","message":"Created it","questions":[],"summary":"Created Shortcut 123","artifacts":[{"label":"Shortcut","url":"https://app.shortcut.com/x/123"}],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

        let result = try AgentTurnContract.decode(json)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.artifacts.first?.label, "Shortcut")
    }

    func test_decodesValidOutcomeSpecificFields() throws {
        let needsInput = #"{"outcome":"needs_input","message":"Need detail","questions":["Which version?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#
        let failed = #"{"outcome":"failed","message":"Could not continue","questions":[],"summary":"","artifacts":[],"retryDisposition":"safe","errorCategory":"network","connectedCapability":null}"#
        let connected = #"{"outcome":"requires_connected_worker","message":"Needs Shortcut","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":"shortcut"}"#

        XCTAssertEqual(try AgentTurnContract.decode(needsInput).outcome, .needsInput)
        XCTAssertEqual(try AgentTurnContract.decode(failed).errorCategory, "network")
        XCTAssertEqual(try AgentTurnContract.decode(connected).connectedCapability, "shortcut")
    }

    func test_acceptsExplicitNullOutcomeFieldsWhenOutcomePermits() throws {
        let completed = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#
        let cancelled = #"{"outcome":"cancelled","message":"Stopped","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

        XCTAssertNil(try AgentTurnContract.decode(completed).errorCategory)
        XCTAssertNil(try AgentTurnContract.decode(cancelled).connectedCapability)
    }

    func test_rejectsMissingNullableKeysEvenWhenOutcomePermitsNull() {
        let missingErrorCategory = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","connectedCapability":null}"#
        let missingConnectedCapability = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null}"#

        XCTAssertThrowsError(try AgentTurnContract.decode(missingErrorCategory))
        XCTAssertThrowsError(try AgentTurnContract.decode(missingConnectedCapability))
    }

    func test_rejectsMissingOrBlankOutcomeSpecificFields() {
        let needsInputCases = [
            #"{"outcome":"needs_input","message":"Need detail","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#,
            #"{"outcome":"needs_input","message":"Need detail","questions":["  "],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#,
        ]
        let failedCases = [
            #"{"outcome":"failed","message":"Failed","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#,
            #"{"outcome":"failed","message":"Failed","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":" \n ","connectedCapability":null}"#,
        ]
        let connectedCases = [
            #"{"outcome":"requires_connected_worker","message":"Blocked","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#,
            #"{"outcome":"requires_connected_worker","message":"Blocked","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":"  "}"#,
        ]

        for json in needsInputCases + failedCases + connectedCases {
            XCTAssertThrowsError(try AgentTurnContract.decode(json), json)
        }
    }

    func test_rejectsOutcomeFieldsThatContradictOutcome() {
        let contradictoryPayloads = [
            #"{"outcome":"completed","message":"Done","questions":["Unexpected?"],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#,
            #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":"none","connectedCapability":null}"#,
            #"{"outcome":"cancelled","message":"Stopped","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":"shortcut"}"#,
            #"{"outcome":"needs_input","message":"Need detail","questions":["Which version?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":"not-an-error","connectedCapability":null}"#,
            #"{"outcome":"needs_input","message":"Need detail","questions":["Which version?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":"shortcut"}"#,
            #"{"outcome":"failed","message":"Failed","questions":["Retry?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":"network","connectedCapability":null}"#,
            #"{"outcome":"failed","message":"Failed","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":"network","connectedCapability":"shortcut"}"#,
            #"{"outcome":"requires_connected_worker","message":"Blocked","questions":["Connect?"],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":"shortcut"}"#,
            #"{"outcome":"requires_connected_worker","message":"Blocked","questions":[],"summary":"","artifacts":[],"retryDisposition":"none","errorCategory":"network","connectedCapability":"shortcut"}"#,
        ]

        for json in contradictoryPayloads {
            XCTAssertThrowsError(try AgentTurnContract.decode(json), json)
        }
    }

    func test_rejectsUnknownOutcomeAndProse() {
        let otherwiseCompleteUnknownOutcome = #"{"outcome":"done","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

        XCTAssertThrowsError(try AgentTurnContract.decode(otherwiseCompleteUnknownOutcome))
        XCTAssertThrowsError(try AgentTurnContract.decode("looks good"))
    }

    func test_decodeRejectsUnknownTopLevelAndArtifactProperties() {
        let unknownTopLevel = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null,"surprise":true}"#
        let unknownArtifact = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[{"label":"File","url":"file:///tmp/result","surprise":true}],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

        XCTAssertThrowsError(try AgentTurnContract.decode(unknownTopLevel))
        XCTAssertThrowsError(try AgentTurnContract.decode(unknownArtifact))
    }

    func test_workerContractContainsHardSafetyRules() throws {
        let text = try AgentTurnContract.workerContract()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        XCTAssertTrue(text.contains("A missing skill is not a reason to decline."))
        XCTAssertTrue(text.contains("Never send email, post messages, purchase, publish, delete external data, or take another irreversible outward action."))
        XCTAssertTrue(text.contains("Every completed task returns to Mustard Needs Review."))
        XCTAssertTrue(text.contains("Return only the JSON object required by the supplied schema."))
        XCTAssertTrue(text.contains("Mustard task UID is the stable idempotency key for outward artifact creation."))
        XCTAssertTrue(text.contains("Before creating a Shortcut or Jira artifact, search for an existing artifact carrying that key; reuse and verify it instead of creating a duplicate during retries or recovery."))
    }

    func test_workerContractDescribesDraftFiles() throws {
        let text = try AgentTurnContract.workerContract()
        XCTAssertTrue(text.contains("_agent/drafts/"))
        XCTAssertTrue(text.contains("drafts[]"))
    }

    func test_schemaRequiresStrictResultAndArtifactShapes() throws {
        let data = Data(AgentTurnContract.jsonSchema.utf8)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let outcome = try XCTUnwrap(properties["outcome"] as? [String: Any])
        let retryDisposition = try XCTUnwrap(properties["retryDisposition"] as? [String: Any])
        let artifacts = try XCTUnwrap(properties["artifacts"] as? [String: Any])
        let artifactItems = try XCTUnwrap(artifacts["items"] as? [String: Any])

        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set([
            "outcome", "message", "questions", "summary", "artifacts", "retryDisposition",
            "errorCategory", "connectedCapability",
        ]))
        XCTAssertEqual(
            outcome["enum"] as? [String],
            ["completed", "needs_input", "failed", "cancelled", "requires_connected_worker"]
        )
        XCTAssertEqual(
            retryDisposition["enum"] as? [String],
            ["none", "safe", "backoff", "uncertain"]
        )
        XCTAssertEqual(artifactItems["additionalProperties"] as? Bool, false)
        XCTAssertEqual(artifactItems["required"] as? [String], ["label", "url"])
        XCTAssertEqual(
            questionsDescription(from: properties),
            "For needs_input, include at least one nonblank question; otherwise use an empty array."
        )
        XCTAssertEqual(
            (properties["errorCategory"] as? [String: Any])?["description"] as? String,
            "For failed, provide a nonblank error category; otherwise use null."
        )
        XCTAssertEqual(
            (properties["connectedCapability"] as? [String: Any])?["description"] as? String,
            "For requires_connected_worker, provide a nonblank capability; otherwise use null."
        )

        let unsupported = Set(["allOf", "if", "then", "contains", "pattern"])
        XCTAssertTrue(schemaKeywords(in: schema).isDisjoint(with: unsupported))
    }

    func test_decodesDraftsWhenPresent() throws {
        let json = #"{"outcome":"completed","message":"done","questions":[],"summary":"Drafted","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null,"drafts":[{"kind":"comment","title":"Jira reply","path":"_agent/drafts/u1/reply.md"}]}"#
        let result = try AgentTurnContract.decode(json)
        XCTAssertEqual(result.drafts?.count, 1)
        XCTAssertEqual(result.drafts?.first?.kind, "comment")
        XCTAssertEqual(result.drafts?.first?.path, "_agent/drafts/u1/reply.md")
    }

    func test_decodesWithoutDraftsKey_defaultsToNil() throws {
        let json = #"{"outcome":"completed","message":"done","questions":[],"summary":"s","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#
        let result = try AgentTurnContract.decode(json)
        XCTAssertNil(result.drafts)
    }

    func test_rejectsUnknownTopLevelKey() {
        let json = #"{"outcome":"completed","message":"m","questions":[],"summary":"s","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null,"bogus":1}"#
        XCTAssertThrowsError(try AgentTurnContract.decode(json))
    }

    func test_resolvedDraftURLConfinesToDraftsFolderThroughSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("drafts-confine-\(UUID().uuidString)", isDirectory: true)
        let outside = fm.temporaryDirectory
            .appendingPathComponent("drafts-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let draftsDir = root.appendingPathComponent("_agent/drafts/u1", isDirectory: true)
        try fm.createDirectory(at: draftsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "safe".write(to: draftsDir.appendingPathComponent("ok.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("target.md"), atomically: true, encoding: .utf8)
        // A symlink planted inside the drafts folder pointing outside the vault.
        try fm.createSymbolicLink(
            at: draftsDir.appendingPathComponent("escape.md"),
            withDestinationURL: outside.appendingPathComponent("target.md")
        )
        // A symlinked DIRECTORY inside the drafts folder pointing outside.
        try fm.createSymbolicLink(
            at: draftsDir.appendingPathComponent("outdir"),
            withDestinationURL: outside
        )

        XCTAssertNotNil(AgentDrafts.resolvedDraftURL(root: root.path, relativePath: "_agent/drafts/u1/ok.md"))
        // A brand-new (not-yet-written) file inside the folder is fine too.
        XCTAssertNotNil(AgentDrafts.resolvedDraftURL(root: root.path, relativePath: "_agent/drafts/u1/new.md"))
        XCTAssertNil(AgentDrafts.resolvedDraftURL(root: root.path, relativePath: "_agent/drafts/u1/escape.md"),
                     "a symlinked file escaping the drafts folder must be rejected")
        XCTAssertNil(AgentDrafts.resolvedDraftURL(root: root.path, relativePath: "_agent/drafts/u1/outdir/target.md"),
                     "a path through a symlinked directory escaping the vault must be rejected")
        XCTAssertNil(AgentDrafts.resolvedDraftURL(root: root.path, relativePath: "notes/elsewhere.md"))
    }

    func test_draftPathSafety() {
        XCTAssertTrue(AgentDrafts.isSafeRelativePath("_agent/drafts/u1/reply.md"))
        XCTAssertFalse(AgentDrafts.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(AgentDrafts.isSafeRelativePath("_agent/drafts/../../secret.md"))
        XCTAssertFalse(AgentDrafts.isSafeRelativePath("notes/elsewhere.md"))
        XCTAssertFalse(AgentDrafts.isSafeRelativePath(""))
    }

    private func questionsDescription(from properties: [String: Any]) -> String? {
        (properties["questions"] as? [String: Any])?["description"] as? String
    }

    private func schemaKeywords(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { result, pair in
                result.formUnion(schemaKeywords(in: pair.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, element in
                result.formUnion(schemaKeywords(in: element))
            }
        }
        return []
    }
}
