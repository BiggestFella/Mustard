import XCTest
@testable import MustardKit

final class GoogleOAuthTests: XCTestCase {
    func test_pkce_matchesRFC7636TestVector() {
        // From RFC 7636 Appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func test_pkce_random_isUrlSafeAndLongEnough() {
        let pkce = PKCE.random()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.verifier.contains("+"))
        XCTAssertFalse(pkce.verifier.contains("/"))
        XCTAssertFalse(pkce.verifier.contains("="))
    }

    func test_authorizationURL_carriesPkceAndOfflineConsent() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(
            clientId: "abc.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:7421/callback",
            pkce: pkce
        )
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], "abc.apps.googleusercontent.com")
        XCTAssertEqual(q["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertTrue(q["scope"]?.contains("calendar") ?? false)
    }

    func test_parseTokenResponse_setsExpiryFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#.data(using: .utf8)!
        let token = GoogleOAuth.parseTokenResponse(json, now: now)
        XCTAssertEqual(token?.accessToken, "at")
        XCTAssertEqual(token?.refreshToken, "rt")
        XCTAssertEqual(token?.expiresAt, now.addingTimeInterval(3600))
    }

    func test_token_isExpired_reflectsClock() {
        let future = GoogleToken(accessToken: "a", refreshToken: nil, expiresAt: .now.addingTimeInterval(3600))
        let past = GoogleToken(accessToken: "a", refreshToken: nil, expiresAt: .now.addingTimeInterval(-10))
        XCTAssertFalse(future.isExpired)
        XCTAssertTrue(past.isExpired)
    }

    func test_parseTokenResponse_garbageReturnsNil() {
        XCTAssertNil(GoogleOAuth.parseTokenResponse(Data("nope".utf8)))
    }

    func testAuthorizationURLUsesInjectedScope() {
        let url = GoogleOAuth.authorizationURL(
            clientId: "id", redirectURI: "http://127.0.0.1:1", pkce: PKCE(verifier: "v"),
            scope: "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.modify")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let scope = items.first { $0.name == "scope" }?.value
        XCTAssertEqual(scope, "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.modify")
    }

    func testAuthorizationURLDefaultsToCalendarScope() {
        let url = GoogleOAuth.authorizationURL(
            clientId: "id", redirectURI: "http://127.0.0.1:1", pkce: PKCE(verifier: "v"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, GoogleOAuth.scope)
    }
}
