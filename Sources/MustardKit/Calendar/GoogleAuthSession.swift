import Foundation

/// Orchestrates the OAuth connect: PKCE → loopback server → browser → code → token.
/// Every side-effecting dependency is injected, so the whole flow is unit-testable.
public struct GoogleAuthSession {
    let makeServer: () -> RedirectServing
    let tokenClient: GoogleTokenClient
    let store: TokenStore
    let openURL: (URL) -> Void
    let scope: String
    let makePKCE: () -> PKCE
    let makeState: () -> String
    let timeout: TimeInterval

    public init(makeServer: @escaping () -> RedirectServing,
                tokenClient: GoogleTokenClient,
                store: TokenStore,
                openURL: @escaping (URL) -> Void,
                scope: String = GoogleOAuth.scope,
                makePKCE: @escaping () -> PKCE = { PKCE.random() },
                makeState: @escaping () -> String = { UUID().uuidString },
                timeout: TimeInterval = 120) {
        self.makeServer = makeServer
        self.tokenClient = tokenClient
        self.store = store
        self.openURL = openURL
        self.scope = scope
        self.makePKCE = makePKCE
        self.makeState = makeState
        self.timeout = timeout
    }

    public func connect(credentials: GoogleCredentials) async throws -> GoogleToken {
        let pkce = makePKCE()
        let state = makeState()
        let server = makeServer()
        let port = try server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"
        openURL(GoogleOAuth.authorizationURL(clientId: credentials.clientId,
                                             redirectURI: redirectURI, pkce: pkce, state: state,
                                             scope: scope))
        let result = try await server.awaitCode(timeout: timeout)
        // Anti-forgery: the returned state must match what we sent, or this redirect
        // didn't originate from our request (auth-code injection / login-CSRF).
        guard result.state == state else { throw GoogleAuthError.server("state mismatch") }
        let token = try await tokenClient.exchange(code: result.code, pkce: pkce,
                                                   redirectURI: redirectURI, credentials: credentials)
        try store.saveCredentials(credentials)
        try store.saveToken(token)
        return token
    }
}
