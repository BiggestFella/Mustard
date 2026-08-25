import XCTest
@testable import MustardKit

final class GmailTriageTests: XCTestCase {
    private let routes = [
        GmailTriage.ProjectRoute(name: "DL-Knowledge-Base",
                                 workingDirectory: "/kb/DL-Knowledge-Base"),
        GmailTriage.ProjectRoute(name: "SB-Knowledge-Base",
                                 workingDirectory: "/kb/SB-Knowledge-Base"),
    ]

    private func email(id: String = "m1", thread: String = "t1", body: String = "please review",
                       labels: [String] = ["Jira Updates"]) -> GmailTriage.EmailContext {
        .init(message: GmailMessage(id: id, threadId: thread, from: "Ana <ana@tmr.qld.gov.au>",
                                    subject: "DLA build",
                                    date: Date(timeIntervalSince1970: 1_780_000_000),
                                    snippet: "snip", body: body),
              labels: labels)
    }

    func testRoutesFromSourceSettingsFiltersEnabledVaultSources() {
        let settings = SourceSettings(sources: [
            SourceConfig(id: .vault, project: "DL-Knowledge-Base", enabled: true, workingDirectory: "/kb/DL-Knowledge-Base"),
            SourceConfig(id: .vault, project: "Off", enabled: false, workingDirectory: "/kb/Off"),
            SourceConfig(id: .vault, project: "NoDir", enabled: true, workingDirectory: ""),
            SourceConfig(id: .gmail, project: "X", enabled: true, workingDirectory: "/x"),
        ], state: [])
        XCTAssertEqual(GmailTriage.routes(from: settings),
                       [GmailTriage.ProjectRoute(name: "DL-Knowledge-Base", workingDirectory: "/kb/DL-Knowledge-Base")])
    }

    func testGroundingDirectoryIsCommonParent() {
        XCTAssertEqual(GmailTriage.groundingDirectory(for: routes), "/kb")
        XCTAssertNil(GmailTriage.groundingDirectory(for: []))
    }

    func testPromptEmbedsEmailsProjectsAndContract() {
        let prompt = GmailTriage.prompt(emails: [email()], projects: routes)
        XCTAssertTrue(prompt.contains("sourceEventID=m1"))
        XCTAssertTrue(prompt.contains("threadID=t1"))
        XCTAssertTrue(prompt.contains("DLA build"))
        XCTAssertTrue(prompt.contains("Jira Updates"))
        XCTAssertTrue(prompt.contains("DL-Knowledge-Base"))
        XCTAssertTrue(prompt.contains("SB-Knowledge-Base"))
        XCTAssertTrue(prompt.contains(#""sourceEventID""#))
        XCTAssertTrue(prompt.contains("draft_email"))
        XCTAssertTrue(prompt.contains("DO NOT SEND"))
    }

    func testPromptTruncatesLongBodies() {
        let long = String(repeating: "x", count: 10_000)
        let prompt = GmailTriage.prompt(emails: [email(body: long)], projects: routes)
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: GmailTriage.maxBodyChars + 1)))
    }

    func testParseJoinsProvenanceFromFetchNotModel() {
        let text = """
        [{"sourceEventID": "m1", "project": "DL-Knowledge-Base", "title": "Reply to Ana",
          "body": "b", "action_type": "draft_email", "confidence": 0.9,
          "reasoning": "r", "draft": "Hi Ana"}]
        """
        guard case .proposals(let ps) = GmailTriage.parseOutcome(text, emails: [email()], projects: routes),
              let p = ps.first else { return XCTFail("expected one proposal") }
        XCTAssertEqual(p.source, .gmail)
        XCTAssertEqual(p.project, "DL-Knowledge-Base")
        XCTAssertEqual(p.sourceItemID, "t1")
        XCTAssertEqual(p.sourceEventID, "m1")
        XCTAssertEqual(p.sourceURL, "https://mail.google.com/mail/u/0/#all/m1")
        XCTAssertEqual(p.occurredAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(p.labels, ["Jira Updates"])
        XCTAssertEqual(p.originalSource, "please review")
        XCTAssertEqual(p.actionType, "draft_email")
        XCTAssertEqual(p.title, "Reply to Ana")
    }

    func testParseDropsUnknownIDsAndProjects() {
        let text = """
        [{"sourceEventID": "ghost", "project": "DL-Knowledge-Base", "title": "t"},
         {"sourceEventID": "m1", "project": "Invented-Project", "title": "t"}]
        """
        guard case .proposals(let ps) = GmailTriage.parseOutcome(text, emails: [email()], projects: routes)
        else { return XCTFail() }
        XCTAssertTrue(ps.isEmpty)
    }

    func testParseUnparseableAndEmptyAreDistinct() {
        XCTAssertEqual(GmailTriage.parseOutcome("no json here", emails: [email()], projects: routes),
                       .unparseable)
        XCTAssertEqual(GmailTriage.parseOutcome("[]", emails: [email()], projects: routes),
                       .proposals([]))
    }

    func testParseClampsConfidence() {
        let text = #"[{"sourceEventID": "m1", "project": "DL-Knowledge-Base", "title": "t", "confidence": 7}]"#
        guard case .proposals(let ps) = GmailTriage.parseOutcome(text, emails: [email()], projects: routes)
        else { return XCTFail() }
        XCTAssertEqual(ps.first?.confidence, 1.0)
    }
}
