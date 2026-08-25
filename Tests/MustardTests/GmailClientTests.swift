import XCTest
@testable import MustardKit

final class GmailClientTests: XCTestCase {
    func testListURL() {
        let url = GmailClient.listURL(labelId: "Label_7", query: "newer_than:3d", maxResults: 25)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "gmail.googleapis.com")
        XCTAssertEqual(c.path, "/gmail/v1/users/me/messages")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["labelIds"], "Label_7")
        XCTAssertEqual(q["q"], "newer_than:3d")
        XCTAssertEqual(q["maxResults"], "25")
    }

    func testListURLOmitsEmptyQuery() {
        let c = URLComponents(url: GmailClient.listURL(labelId: "INBOX", query: "", maxResults: 10),
                              resolvingAgainstBaseURL: false)!
        XCTAssertFalse(c.queryItems!.contains { $0.name == "q" })
    }

    func testMessageURLRequestsFullFormat() {
        let c = URLComponents(url: GmailClient.messageURL(id: "m1"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.path, "/gmail/v1/users/me/messages/m1")
        XCTAssertEqual(c.queryItems?.first { $0.name == "format" }?.value, "full")
    }

    func testFetchSetsBearerAndParses() async throws {
        var captured: URLRequest?
        let client = GmailClient(transport: { req in
            captured = req
            return (Data(#"{"messages":[{"id":"m1"}]}"#.utf8), 200)
        })
        let ids = try await client.listMessageIDs(accessToken: "tok", labelId: "INBOX", query: "", maxResults: 5)
        XCTAssertEqual(ids, ["m1"])
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func test401MapsToInvalidGrant() async {
        let client = GmailClient(transport: { _ in (Data(), 401) })
        do {
            _ = try await client.listMessageIDs(accessToken: "t", labelId: "INBOX", query: "", maxResults: 5)
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .invalidGrant) }
    }

    func testNon2xxThrowsServerError() async {
        let client = GmailClient(transport: { _ in (Data("boom".utf8), 500) })
        do {
            _ = try await client.fetchLabels(accessToken: "t")
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .server("gmail status 500")) }
    }

    func testArchivePostsRemoveInboxOnly() async throws {
        var captured: URLRequest?
        let client = GmailClient(transport: { req in captured = req; return (Data("{}".utf8), 200) })
        try await client.archive(accessToken: "t", id: "m9")
        XCTAssertEqual(captured?.url?.path, "/gmail/v1/users/me/messages/m9/modify")
        XCTAssertEqual(captured?.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: captured!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["removeLabelIds"] as? [String], ["INBOX"])
        XCTAssertNil(body["addLabelIds"])   // archive is remove-only, never a delete
    }

    func testSendPostsRawAndThreadIdAndReturnsID() async throws {
        var captured: URLRequest?
        let client = GmailClient(transport: { req in captured = req; return (Data(#"{"id":"sent1"}"#.utf8), 200) })
        let id = try await client.send(accessToken: "t", raw: "QUJD", threadId: "t42")
        XCTAssertEqual(id, "sent1")
        XCTAssertEqual(captured?.url?.path, "/gmail/v1/users/me/messages/send")
        let body = try JSONSerialization.jsonObject(with: captured!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["raw"] as? String, "QUJD")
        XCTAssertEqual(body["threadId"] as? String, "t42")
    }

    func testSendThrowsWhenResponseLacksID() async {
        let client = GmailClient(transport: { _ in (Data("{}".utf8), 200) })
        do {
            _ = try await client.send(accessToken: "t", raw: "QUJD", threadId: nil)
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .server("unparseable send response")) }
    }

    func testFetchMessageThrowsOnUnparseableBody() async {
        let client = GmailClient(transport: { _ in (Data("{}".utf8), 200) })
        do {
            _ = try await client.fetchMessage(accessToken: "t", id: "m1")
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .server("unparseable message m1")) }
    }
}
