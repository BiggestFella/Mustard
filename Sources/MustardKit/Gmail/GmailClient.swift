import Foundation

/// HTTP for the Gmail API. URL builders are pure; the network is the injected
/// `HTTPTransport`; parsing delegates to `GmailParser`. Mirrors `GoogleEventsClient`,
/// including its rule: fail loudly on non-2xx (an error body would otherwise parse
/// to empty results), with 401 → `invalidGrant` so the service clears the token.
public struct GmailClient {
    let transport: HTTPTransport

    public init(transport: @escaping HTTPTransport = GoogleTokenClient.defaultTransport) {
        self.transport = transport
    }

    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    public static func listURL(labelId: String, query: String, maxResults: Int) -> URL {
        var c = URLComponents(string: "\(base)/messages")!
        var items: [URLQueryItem] = [
            .init(name: "labelIds", value: labelId),
            .init(name: "maxResults", value: String(maxResults)),
        ]
        if !query.isEmpty { items.append(.init(name: "q", value: query)) }
        c.queryItems = items
        return c.url!
    }

    public static func messageURL(id: String) -> URL {
        var c = URLComponents(string: "\(base)/messages/\(id)")!
        c.queryItems = [.init(name: "format", value: "full")]
        return c.url!
    }

    public static func labelsURL() -> URL { URL(string: "\(base)/labels")! }
    public static func modifyURL(id: String) -> URL { URL(string: "\(base)/messages/\(id)/modify")! }
    public static func sendURL() -> URL { URL(string: "\(base)/messages/send")! }

    public func listMessageIDs(accessToken: String, labelId: String, query: String,
                               maxResults: Int) async throws -> [String] {
        GmailParser.parseMessageList(
            try await get(Self.listURL(labelId: labelId, query: query, maxResults: maxResults),
                          accessToken: accessToken))
    }

    public func fetchMessage(accessToken: String, id: String) async throws -> GmailMessage {
        let data = try await get(Self.messageURL(id: id), accessToken: accessToken)
        guard let message = GmailParser.parseMessage(data) else {
            throw GoogleAuthError.server("unparseable message \(id)")
        }
        return message
    }

    public func fetchLabels(accessToken: String) async throws -> [GmailLabel] {
        GmailParser.parseLabels(try await get(Self.labelsURL(), accessToken: accessToken))
    }

    /// Archive = remove the INBOX label. Never a delete (spec contract).
    public func archive(accessToken: String, id: String) async throws {
        _ = try await post(Self.modifyURL(id: id), accessToken: accessToken,
                           json: ["removeLabelIds": ["INBOX"]])
    }

    /// Send a raw RFC 2822 message (base64url-encoded), threaded when `threadId`
    /// is non-empty. Returns the sent message's id.
    public func send(accessToken: String, raw: String, threadId: String?) async throws -> String {
        var body: [String: Any] = ["raw": raw]
        if let threadId, !threadId.isEmpty { body["threadId"] = threadId }
        let data = try await post(Self.sendURL(), accessToken: accessToken, json: body)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["id"] as? String ?? ""
    }

    private func get(_ url: URL, accessToken: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await run(req)
    }

    private func post(_ url: URL, accessToken: String, json: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await run(req)
    }

    private func run(_ req: URLRequest) async throws -> Data {
        let (data, status) = try await transport(req)
        guard (200..<300).contains(status) else {
            throw status == 401 ? GoogleAuthError.invalidGrant
                                : GoogleAuthError.server("gmail status \(status)")
        }
        return data
    }
}
