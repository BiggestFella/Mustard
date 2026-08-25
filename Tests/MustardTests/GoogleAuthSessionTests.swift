import XCTest
@testable import MustardKit

final class GoogleAuthSessionTests: XCTestCase {
    func testConnectExchangesAndPersists() async throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#
        let store = InMemoryTokenStore()
        var openedURL: URL?
        let session = GoogleAuthSession(
            makeServer: { StubRedirectServer(port: 5123, result: .init(code: "the-code", state: "fixed-state")) },
            tokenClient: GoogleTokenClient(transport: { _ in (Data(json.utf8), 200) }),
            store: store,
            openURL: { openedURL = $0 },
            makePKCE: { PKCE(verifier: "fixed-verifier") },
            makeState: { "fixed-state" })
        let creds = GoogleCredentials(clientId: "cid", clientSecret: "sec")
        let token = try await session.connect(credentials: creds)

        XCTAssertEqual(token.accessToken, "AT")
        XCTAssertEqual(try store.loadToken(), token)
        XCTAssertEqual(try store.loadCredentials(), creds)
        XCTAssertEqual(openedURL?.absoluteString.contains("client_id=cid"), true)
        XCTAssertEqual(openedURL?.absoluteString.contains("state=fixed-state"), true)
        XCTAssertEqual(openedURL?.absoluteString.contains("127.0.0.1:5123"), true)
    }

    func testStateMismatchRejected() async {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#
        let store = InMemoryTokenStore()
        let session = GoogleAuthSession(
            makeServer: { StubRedirectServer(port: 5123, result: .init(code: "the-code", state: "attacker-state")) },
            tokenClient: GoogleTokenClient(transport: { _ in (Data(json.utf8), 200) }),
            store: store,
            openURL: { _ in },
            makePKCE: { PKCE(verifier: "v") },
            makeState: { "our-state" })
        do {
            _ = try await session.connect(credentials: .init(clientId: "c", clientSecret: "s"))
            XCTFail("expected state-mismatch throw")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .server("state mismatch"))
        }
        XCTAssertNil(try store.loadToken())   // nothing persisted on mismatch
    }

    func testConnectRequestsInjectedScope() async throws {
        var opened: URL?
        let session = GoogleAuthSession(
            makeServer: { StubRedirectServer(port: 7777, result: RedirectResult(code: "c", state: "s")) },
            tokenClient: GoogleTokenClient(transport: { _ in
                (Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8), 200)
            }),
            store: InMemoryTokenStore(),
            openURL: { opened = $0 },
            scope: "scope-a scope-b",
            makePKCE: { PKCE(verifier: "v") },
            makeState: { "s" })
        _ = try await session.connect(credentials: .init(clientId: "i", clientSecret: "x"))
        let items = URLComponents(url: opened!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "scope-a scope-b")
    }
}
