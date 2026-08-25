import Foundation
import CryptoKit

/// PKCE pair (RFC 7636). Verifier is high-entropy; challenge = base64url(SHA256(verifier)).
public struct PKCE: Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// A fresh random verifier (43–128 chars of the unreserved set).
    public static func random() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct GoogleToken: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public var isExpired: Bool { Date.now >= expiresAt }
}

/// Pure OAuth helpers: build the consent URL, parse the token response.
public enum GoogleOAuth {
    public static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    public static func authorizationURL(
        clientId: String, redirectURI: String, pkce: PKCE, state: String? = nil,
        scope: String = GoogleOAuth.scope
    ) -> URL {
        var comps = URLComponents(string: authEndpoint)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        if let state, !state.isEmpty { items.append(.init(name: "state", value: state)) }
        comps.queryItems = items
        return comps.url!
    }

    /// Parse Google's token JSON. `now` injectable for deterministic expiry.
    public static func parseTokenResponse(
        _ data: Data, now: Date = .now
    ) -> GoogleToken? {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return GoogleToken(
            accessToken: r.access_token,
            refreshToken: r.refresh_token,
            expiresAt: now.addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        )
    }
}
