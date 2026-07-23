import XCTest
@testable import MustardKit

final class SourceProposalTests: XCTestCase {
    func test_vaultProposal_mapsToSourceProposalWithStableIdentity() {
        let p = VaultSweep.Proposal(
            title: "Email Bob", body: "about the X migration",
            actionType: "draft_email", confidence: 0.8,
            reasoning: "he asked", draft: "Hi Bob,"
        )

        let sp = SourceProposal(vault: p, project: "DL")

        XCTAssertEqual(sp.source, .vault)
        XCTAssertEqual(sp.title, "Email Bob")
        XCTAssertEqual(sp.actionType, "draft_email")
        XCTAssertEqual(sp.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(sp.draft, "Hi Bob,")
        XCTAssertFalse(sp.sourceEventID.isEmpty, "vault proposals must carry a stable event id")
        // Deterministic across constructions — required for dedupe across repeated sweeps.
        XCTAssertEqual(SourceProposal(vault: p, project: "DL").sourceEventID, sp.sourceEventID)
    }

    func test_vaultProposal_distinctContentGivesDistinctIdentity() {
        let a = VaultSweep.Proposal(title: "A", body: "one", actionType: "vault_note",
                                    confidence: 0.5, reasoning: "", draft: "")
        let b = VaultSweep.Proposal(title: "B", body: "two", actionType: "vault_note",
                                    confidence: 0.5, reasoning: "", draft: "")
        XCTAssertNotEqual(SourceProposal(vault: a, project: "DL").sourceEventID,
                          SourceProposal(vault: b, project: "DL").sourceEventID)
    }

    // Multi-project isolation: the identity must be project-qualified so the same
    // note text in two different KBs can never collide in dedupe.
    func test_vaultProposal_sameContentDifferentProject_distinctIdentity() {
        let p = VaultSweep.Proposal(title: "Status Dashboard", body: "weekly rollup",
                                    actionType: "vault_note", confidence: 0.5, reasoning: "", draft: "x")
        let dl = SourceProposal(vault: p, project: "DL")
        let sandvik = SourceProposal(vault: p, project: "Sandvik")
        XCTAssertEqual(dl.project, "DL")
        XCTAssertEqual(sandvik.project, "Sandvik")
        XCTAssertNotEqual(dl.sourceEventID, sandvik.sourceEventID,
                          "identical note content in different KBs must not share identity")
        XCTAssertNotEqual(dl.sourceItemID, sandvik.sourceItemID)
    }

    func test_vaultProposal_sameContentSameProject_stableIdentity() {
        let p = VaultSweep.Proposal(title: "Status Dashboard", body: "weekly rollup",
                                    actionType: "vault_note", confidence: 0.5, reasoning: "", draft: "x")
        XCTAssertEqual(SourceProposal(vault: p, project: "DL").sourceEventID,
                       SourceProposal(vault: p, project: "DL").sourceEventID)
    }

    // The cloud routine writes grounded recs as JSON into a `_recs/` folder; the Mac
    // decodes them. This pins the on-disk contract between routine and InboxIngest.
    func test_sourceProposal_decodesFromRoutineJSON() throws {
        let json = """
        {"source":"gmail","project":"DL","sourceItemID":"thread-1","sourceEventID":"msg-9",
         "sourceContext":"Jira · PROJ-123","sourceURL":"https://x","occurredAt":"2026-06-17T02:10:00Z",
         "title":"Reply to Alice","body":"she asked for the figures","actionType":"draft_email",
         "confidence":0.8,"reasoning":"thread + DEF-123 note","draft":"Hi Alice,"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(SourceProposal.self, from: Data(json.utf8))
        XCTAssertEqual(p.source, .gmail)
        XCTAssertEqual(p.project, "DL")
        XCTAssertEqual(p.sourceEventID, "msg-9")
        XCTAssertEqual(p.actionType, "draft_email")
        XCTAssertEqual(p.confidence, 0.8, accuracy: 0.001)
    }

    func test_sourceProposal_carriesOriginalSource_roundTrip() throws {
        let p = SourceProposal(source: .gmail, project: "DL", sourceItemID: "t", sourceEventID: "e",
                               title: "x", actionType: "fyi", originalSource: "raw email body")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SourceProposal.self, from: enc.encode(p))
        XCTAssertEqual(back.originalSource, "raw email body")
        XCTAssertEqual(p, back)
    }

    func test_sourceProposal_decodesWhenOriginalSourceAbsent() throws {
        let json = #"{"source":"gmail","project":"DL","sourceItemID":"t","sourceEventID":"e","sourceContext":"","title":"x","body":"","actionType":"fyi","confidence":0.5,"reasoning":"","draft":""}"#
        let p = try JSONDecoder().decode(SourceProposal.self, from: Data(json.utf8))
        XCTAssertNil(p.originalSource)
    }

    func test_sourceProposal_codableRoundTrip() throws {
        let p = SourceProposal(source: .gmail, project: "DL", sourceItemID: "t", sourceEventID: "e",
                               sourceContext: "ctx", title: "x", actionType: "draft_email", confidence: 0.9)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SourceProposal.self, from: enc.encode(p))
        XCTAssertEqual(p, back)
    }

    func test_sourceID_jiraAndShortcut_rawValues() {
        XCTAssertEqual(SourceID(rawValue: "jira"), .jira)
        XCTAssertEqual(SourceID(rawValue: "shortcut"), .shortcut)
    }

    func test_reclassified_overridesSourceAndAction_preservesEverythingElse() {
        let p = SourceProposal(
            source: .gmail, project: "DL", sourceItemID: "t1", sourceEventID: "e1",
            sourceContext: "Jira · DLA-5280", sourceURL: "https://x", title: "T", body: "B",
            actionType: "ticket_write", originalSource: "raw", confidence: 0.8,
            reasoning: "r", draft: "d"
        )
        let out = p.reclassified(source: .jira, actionType: "create_task")
        XCTAssertEqual(out.source, .jira)
        XCTAssertEqual(out.actionType, "create_task")
        XCTAssertEqual(out.project, "DL")
        XCTAssertEqual(out.sourceItemID, "t1")
        XCTAssertEqual(out.sourceEventID, "e1")
        XCTAssertEqual(out.sourceContext, "Jira · DLA-5280")
        XCTAssertEqual(out.sourceURL, "https://x")
        XCTAssertEqual(out.title, "T")
        XCTAssertEqual(out.body, "B")
        XCTAssertEqual(out.originalSource, "raw")
        XCTAssertEqual(out.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(out.reasoning, "r")
        XCTAssertEqual(out.draft, "d")
    }

    // The scout's Gmail thread labels are the ground-truth source signal (see
    // SourceClassifier); the field must round-trip through decode and reclassify.
    func test_sourceProposal_decodesLabelsFromRoutineJSON() throws {
        let json = #"{"source":"gmail","project":"DL","sourceItemID":"t","sourceEventID":"e","sourceContext":"","labels":["Shortcut Notifications","Inbox"],"title":"x","body":"","actionType":"fyi","confidence":0.5,"reasoning":"","draft":""}"#
        let p = try JSONDecoder().decode(SourceProposal.self, from: Data(json.utf8))
        XCTAssertEqual(p.labels, ["Shortcut Notifications", "Inbox"])
    }

    func test_sourceProposal_decodesWhenLabelsAbsent() throws {
        let json = #"{"source":"gmail","project":"DL","sourceItemID":"t","sourceEventID":"e","sourceContext":"","title":"x","body":"","actionType":"fyi","confidence":0.5,"reasoning":"","draft":""}"#
        let p = try JSONDecoder().decode(SourceProposal.self, from: Data(json.utf8))
        XCTAssertNil(p.labels)
    }

    func test_reclassified_preservesLabels() {
        let p = SourceProposal(source: .gmail, project: "DL", sourceItemID: "t", sourceEventID: "e",
                               title: "x", actionType: "fyi", labels: ["Jira Updates"])
        let out = p.reclassified(source: .jira, actionType: "create_task")
        XCTAssertEqual(out.labels, ["Jira Updates"])
    }

    func test_withSourceURL_overridesOnlyURL_preservesEverythingElse() {
        let p = SourceProposal(source: .shortcut, project: "DL", sourceItemID: "t", sourceEventID: "e",
                               sourceURL: "https://browse.jira.com/DLA-1", title: "T", actionType: "create_task")
        let out = p.withSourceURL(nil)
        XCTAssertNil(out.sourceURL)
        XCTAssertEqual(out.source, .shortcut)
        XCTAssertEqual(out.title, "T")
        XCTAssertEqual(out.actionType, "create_task")
    }
}
