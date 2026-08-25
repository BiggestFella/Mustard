# Gmail Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In-app Gmail inbox — Mustard polls Gmail directly via OAuth + the Gmail API, triages new mail through `claude -p` into the existing Recommendation pipeline, and supports explicit archive / reply-send from the card.

**Architecture:** Reuse the Calendar OAuth stack (PKCE, `GoogleAuthSession`, `GoogleTokenClient`, Keychain) with a parameterized scope; a new `Sources/MustardKit/Gmail/` layer mirrors the Calendar layer's shapes (`GmailClient` ≈ `GoogleEventsClient`, `GmailService` ≈ `GoogleCalendarService`); triage output joins deterministically back to fetched messages and enters `AgentService` through a new `ingestExternal` that reuses normalize → dedupe → insert → trust. No SwiftData schema changes.

**Tech Stack:** Swift 6.2 (Swift-5 mode), SwiftUI, SwiftData (read-only reuse), XCTest, Gmail REST API v1. Spec: `docs/specs/2026-08-25-gmail-inbox.md`.

**Repo rules that bind every task:** TDD for anything in `Logic/`/`Agent/`/`Calendar/`/`Gmail/` (failing test first); pin time with injected `now:`; network via `HTTPTransport` stubs; views are build-verified only; commit format `type(scope): summary` + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; run `swift test` via exit code, never grep. New Gmail files MUST compile for iOS (`./build-ios.sh`) — no AppKit imports outside `Views/`, no new project.yml excludes.

---

### Task 1: Parameterize the OAuth scope

**Files:**
- Modify: `Sources/MustardKit/Calendar/GoogleOAuth.swift:50-67`
- Modify: `Sources/MustardKit/Calendar/GoogleAuthSession.swift`
- Test: `Tests/MustardTests/GoogleOAuthTests.swift`, `Tests/MustardTests/GoogleAuthSessionTests.swift`

- [ ] **Step 1: Failing tests.** Append to `GoogleOAuthTests.swift`:

```swift
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
```

And to `GoogleAuthSessionTests.swift` (reuse its existing stub wiring — `StubRedirectServer`, deterministic `makePKCE`/`makeState`, captured `openURL`; copy the setup of an existing test in that file and change only the assertions):

```swift
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
```

(Adjust the `StubRedirectServer` initializer call to match its actual signature in `Tests/MustardTests/StubRedirectServer.swift` — read that file first.)

- [ ] **Step 2:** `swift test --filter GoogleOAuthTests 2>&1; echo EXIT:$?` — expect compile failure (no `scope:` parameter).
- [ ] **Step 3: Implement.** In `GoogleOAuth.swift`, change the signature and the scope item:

```swift
public static func authorizationURL(
    clientId: String, redirectURI: String, pkce: PKCE, state: String? = nil,
    scope: String = GoogleOAuth.scope
) -> URL {
```

and inside the items array: `.init(name: "scope", value: scope),`

In `GoogleAuthSession.swift`: add a stored `let scope: String`, an init parameter `scope: String = GoogleOAuth.scope` (placed after `openURL`, before `makePKCE`), assign it, and pass `scope: scope` in the `GoogleOAuth.authorizationURL(...)` call inside `connect`.

- [ ] **Step 4:** `swift test --filter "GoogleOAuthTests|GoogleAuthSessionTests" 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5: Commit** `feat(oauth): parameterize the Google OAuth scope for Gmail`

---

### Task 2: GmailMessage + GmailParser

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailMessage.swift`
- Create: `Sources/MustardKit/Gmail/GmailParser.swift`
- Test: `Tests/MustardTests/GmailParserTests.swift`

- [ ] **Step 1: Value types** (no test needed for plain data):

```swift
import Foundation

/// One fetched Gmail message, flattened from the API's nested payload into the
/// fields triage and reply need. Pure value type; `GmailParser` builds it.
public struct GmailMessage: Equatable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]
    public let from: String
    public let to: String
    public let replyTo: String
    public let subject: String
    /// RFC 5322 Message-ID header — reply threading (In-Reply-To/References).
    public let messageIdHeader: String
    public let references: String
    public let date: Date?
    public let snippet: String
    public let body: String

    public init(id: String, threadId: String, labelIds: [String] = [], from: String = "",
                to: String = "", replyTo: String = "", subject: String = "",
                messageIdHeader: String = "", references: String = "", date: Date? = nil,
                snippet: String = "", body: String = "") {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.from = from
        self.to = to
        self.replyTo = replyTo
        self.subject = subject
        self.messageIdHeader = messageIdHeader
        self.references = references
        self.date = date
        self.snippet = snippet
        self.body = body
    }
}

public struct GmailLabel: Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
```

- [ ] **Step 2: Failing tests** — `Tests/MustardTests/GmailParserTests.swift` (inline raw-string fixtures, the repo idiom):

```swift
import XCTest
@testable import MustardKit

final class GmailParserTests: XCTestCase {
    func testParseMessageListExtractsIDsInOrder() {
        let json = #"{"messages":[{"id":"m3","threadId":"t3"},{"id":"m2","threadId":"t2"}],"resultSizeEstimate":2}"#
        XCTAssertEqual(GmailParser.parseMessageList(Data(json.utf8)), ["m3", "m2"])
    }

    func testParseMessageListEmptyAndMalformed() {
        XCTAssertEqual(GmailParser.parseMessageList(Data("{}".utf8)), [])
        XCTAssertEqual(GmailParser.parseMessageList(Data("not json".utf8)), [])
    }

    func testParseLabels() {
        let json = #"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"Label_7","name":"Clients/TMR"}]}"#
        XCTAssertEqual(GmailParser.parseLabels(Data(json.utf8)),
                       [GmailLabel(id: "INBOX", name: "INBOX"), GmailLabel(id: "Label_7", name: "Clients/TMR")])
    }

    func testDecodeBase64URLHandlesURLAlphabetAndMissingPadding() {
        // "hi?~" base64 is "aGk/fg==" → base64url "aGk_fg" (no padding).
        XCTAssertEqual(GmailParser.decodeBase64URL("aGk_fg").flatMap { String(data: $0, encoding: .utf8) }, "hi?~")
    }

    func testParseMessagePrefersNestedTextPlainPart() {
        // multipart/alternative with html first, plain nested one level down.
        let plainB64 = Data("plain wins".utf8).base64URLEncodedString()
        let htmlB64 = Data("<p>html</p>".utf8).base64URLEncodedString()
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","Label_7"],"internalDate":"1780000000000",
         "snippet":"snip",
         "payload":{"mimeType":"multipart/mixed","headers":[
            {"name":"From","value":"Ana <ana@tmr.qld.gov.au>"},
            {"name":"To","value":"leon@codeheroes.com.au"},
            {"name":"Subject","value":"DLA build"},
            {"name":"Message-ID","value":"<abc@mail.gmail.com>"},
            {"name":"References","value":"<root@x>"}],
          "parts":[
            {"mimeType":"text/html","body":{"data":"\(htmlB64)"}},
            {"mimeType":"multipart/alternative","parts":[
               {"mimeType":"text/plain","body":{"data":"\(plainB64)"}}]}]}}
        """
        let m = GmailParser.parseMessage(Data(json.utf8))
        XCTAssertEqual(m?.id, "m1")
        XCTAssertEqual(m?.threadId, "t1")
        XCTAssertEqual(m?.labelIds, ["INBOX", "Label_7"])
        XCTAssertEqual(m?.from, "Ana <ana@tmr.qld.gov.au>")
        XCTAssertEqual(m?.subject, "DLA build")
        XCTAssertEqual(m?.messageIdHeader, "<abc@mail.gmail.com>")
        XCTAssertEqual(m?.references, "<root@x>")
        XCTAssertEqual(m?.date, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(m?.body, "plain wins")
    }

    func testParseMessageFallsBackToStrippedHTML() {
        let htmlB64 = Data("<html><style>p{}</style><p>Hello&nbsp;&amp; welcome</p><br>bye</html>".utf8).base64URLEncodedString()
        let json = #"{"id":"m2","threadId":"t2","payload":{"mimeType":"text/html","body":{"data":"\#(htmlB64)"},"headers":[]}}"#
        let m = GmailParser.parseMessage(Data(json.utf8))
        XCTAssertEqual(m?.body, "Hello & welcome\nbye")
    }

    func testParseMessageRejectsMissingIdentity() {
        XCTAssertNil(GmailParser.parseMessage(Data(#"{"threadId":"t"}"#.utf8)))
        XCTAssertNil(GmailParser.parseMessage(Data("nope".utf8)))
    }

    func testHeaderLookupIsCaseInsensitive() {
        let json = #"{"id":"m3","threadId":"t3","payload":{"headers":[{"name":"message-id","value":"<x@y>"}]}}"#
        XCTAssertEqual(GmailParser.parseMessage(Data(json.utf8))?.messageIdHeader, "<x@y>")
    }
}
```

- [ ] **Step 3:** `swift test --filter GmailParserTests 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 4: Implement** `Sources/MustardKit/Gmail/GmailParser.swift`:

```swift
import Foundation

/// Pure parsers for Gmail API JSON (list / get / labels) plus the base64url and
/// HTML-stripping helpers they need. Mirrors `GoogleCalendarParser`'s role.
public enum GmailParser {
    /// `messages.list` → ids, in the API's newest-first order.
    public static func parseMessageList(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { $0["id"] as? String }
    }

    /// `labels.list` → id/name pairs (system + user labels alike).
    public static func parseLabels(_ data: Data) -> [GmailLabel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let labels = root["labels"] as? [[String: Any]] else { return [] }
        return labels.compactMap { l in
            guard let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
            return GmailLabel(id: id, name: name)
        }
    }

    /// `messages.get?format=full` → `GmailMessage`. nil when id/threadId are missing.
    public static func parseMessage(_ data: Data) -> GmailMessage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["id"] as? String,
              let threadId = root["threadId"] as? String else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            headers.first {
                ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }?["value"] as? String ?? ""
        }
        let ms = (root["internalDate"] as? String).flatMap(Double.init)
        return GmailMessage(
            id: id, threadId: threadId,
            labelIds: root["labelIds"] as? [String] ?? [],
            from: header("From"), to: header("To"), replyTo: header("Reply-To"),
            subject: header("Subject"), messageIdHeader: header("Message-ID"),
            references: header("References"),
            date: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
            snippet: root["snippet"] as? String ?? "",
            body: extractBody(payload))
    }

    /// Depth-first: first text/plain part wins; else first text/html tag-stripped;
    /// else empty (callers fall back to `snippet`).
    static func extractBody(_ payload: [String: Any]) -> String {
        if let plain = firstPart(payload, mime: "text/plain") { return plain }
        if let html = firstPart(payload, mime: "text/html") { return strippedHTML(html) }
        return ""
    }

    private static func firstPart(_ part: [String: Any], mime: String) -> String? {
        if (part["mimeType"] as? String)?.caseInsensitiveCompare(mime) == .orderedSame,
           let body = part["body"] as? [String: Any],
           let dataString = body["data"] as? String,
           let data = decodeBase64URL(dataString),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        for sub in part["parts"] as? [[String: Any]] ?? [] {
            if let found = firstPart(sub, mime: mime) { return found }
        }
        return nil
    }

    /// Gmail bodies are base64url without padding (RFC 4648 §5).
    public static func decodeBase64URL(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    /// Minimal, dependency-free HTML → text for html-only emails: drop
    /// style/script/head blocks, keep line structure from <br>/</p>, strip the
    /// rest of the tags, decode the common entities, collapse blank-line runs.
    public static func strippedHTML(_ html: String) -> String {
        var text = html
        for block in ["style", "script", "head"] {
            text = text.replacingOccurrences(
                of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, plain) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                                ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 5:** `swift test --filter GmailParserTests 2>&1; echo EXIT:$?` — expect EXIT:0. If the html-fallback assertion fails on exact whitespace, fix the *implementation's* whitespace handling, not the expectation's intent (readable text, entities decoded, no tags).
- [ ] **Step 6: Commit** `feat(gmail): message model and API JSON parser`

---

### Task 3: GmailClient

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailClient.swift`
- Test: `Tests/MustardTests/GmailClientTests.swift`

- [ ] **Step 1: Failing tests:**

```swift
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

    func testFetchMessageThrowsOnUnparseableBody() async {
        let client = GmailClient(transport: { _ in (Data("{}".utf8), 200) })
        do {
            _ = try await client.fetchMessage(accessToken: "t", id: "m1")
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .server("unparseable message m1")) }
    }
}
```

- [ ] **Step 2:** `swift test --filter GmailClientTests 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 3: Implement:**

```swift
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
```

- [ ] **Step 4:** `swift test --filter GmailClientTests 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5: Commit** `feat(gmail): Gmail API client with injected transport`

---

### Task 4: GmailMime (reply construction)

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailMime.swift`
- Test: `Tests/MustardTests/GmailMimeTests.swift`

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import MustardKit

final class GmailMimeTests: XCTestCase {
    func testReplySubjectAddsRePrefixOnce() {
        XCTAssertEqual(GmailMime.replySubject("DLA build"), "Re: DLA build")
        XCTAssertEqual(GmailMime.replySubject("Re: DLA build"), "Re: DLA build")
        XCTAssertEqual(GmailMime.replySubject("RE: DLA build"), "RE: DLA build")
    }

    func testReplyReferencesAppendsParentMessageID() {
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "<a@x> <b@x>", parentMessageID: "<c@x>"),
                       "<a@x> <b@x> <c@x>")
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "", parentMessageID: "<c@x>"), "<c@x>")
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "", parentMessageID: ""), "")
    }

    func testMessageHasThreadingHeadersAndBase64Body() {
        let mime = GmailMime.message(
            to: "ana@tmr.qld.gov.au", subject: "Re: DLA build", body: "On it — fix lands today.",
            inReplyTo: "<abc@x>", references: "<root@x> <abc@x>")
        let lines = mime.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("To: ana@tmr.qld.gov.au"))
        XCTAssertTrue(lines.contains("Subject: Re: DLA build"))
        XCTAssertTrue(lines.contains("In-Reply-To: <abc@x>"))
        XCTAssertTrue(lines.contains("References: <root@x> <abc@x>"))
        XCTAssertTrue(lines.contains("MIME-Version: 1.0"))
        XCTAssertTrue(lines.contains("Content-Type: text/plain; charset=\"UTF-8\""))
        XCTAssertTrue(lines.contains("Content-Transfer-Encoding: base64"))
        // Blank line separates headers from body; body decodes back to the input.
        let split = mime.range(of: "\r\n\r\n")
        XCTAssertNotNil(split)
        let bodyPart = String(mime[split!.upperBound...]).replacingOccurrences(of: "\r\n", with: "")
        XCTAssertEqual(Data(base64Encoded: bodyPart).flatMap { String(data: $0, encoding: .utf8) },
                       "On it — fix lands today.")
    }

    func testNonASCIISubjectIsRFC2047Encoded() {
        let mime = GmailMime.message(to: "a@b.c", subject: "Résumé ✅", body: "x")
        XCTAssertTrue(mime.contains("Subject: =?UTF-8?B?"))
    }

    func testHeaderInjectionIsNeutralized() {
        let mime = GmailMime.message(to: "a@b.c\r\nBcc: evil@x.y", subject: "hi\nX-Evil: 1", body: "x")
        XCTAssertFalse(mime.contains("Bcc: evil@x.y"))
        XCTAssertFalse(mime.contains("X-Evil: 1"))
    }

    func testOmitsEmptyThreadingHeaders() {
        let mime = GmailMime.message(to: "a@b.c", subject: "s", body: "x")
        XCTAssertFalse(mime.contains("In-Reply-To:"))
        XCTAssertFalse(mime.contains("References:"))
    }
}
```

- [ ] **Step 2:** `swift test --filter GmailMimeTests 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 3: Implement:**

```swift
import Foundation

/// Builds the RFC 2822 reply/new message that `messages.send` wants as base64url
/// `raw`. Pure. Gmail stamps From/Date itself. Headers are sanitized against
/// CR/LF injection; the body travels base64 so any UTF-8 content is safe.
public enum GmailMime {
    /// "Re: " prefix unless one (any case) is already present.
    public static func replySubject(_ original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: \(trimmed)"
    }

    /// RFC 5322 chain: the parent's References plus the parent's own Message-ID.
    public static func replyReferences(parentReferences: String, parentMessageID: String) -> String {
        [parentReferences, parentMessageID]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func message(
        to: String, subject: String, body: String,
        inReplyTo: String = "", references: String = ""
    ) -> String {
        var lines = [
            "To: \(sanitized(to))",
            "Subject: \(encodedSubject(subject))",
        ]
        if !inReplyTo.isEmpty { lines.append("In-Reply-To: \(sanitized(inReplyTo))") }
        if !references.isEmpty { lines.append("References: \(sanitized(references))") }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(body.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
        return lines.joined(separator: "\r\n")
    }

    /// Any CR/LF in a header value would start a forged header — flatten to spaces.
    static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// RFC 2047 encoded-word for non-ASCII subjects; plain (sanitized) otherwise.
    static func encodedSubject(_ subject: String) -> String {
        let clean = sanitized(subject)
        guard clean.allSatisfy(\.isASCII) else {
            return "=?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?="
        }
        return clean
    }
}
```

- [ ] **Step 4:** `swift test --filter GmailMimeTests 2>&1; echo EXIT:$?` — expect EXIT:0. (If the base64 line-wrapping option names differ under this SDK, use `Data.Base64EncodingOptions([.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])` — the test tolerates wrapping because it strips `\r\n` before decoding.)
- [ ] **Step 5: Commit** `feat(gmail): RFC 2822 reply builder with injection-safe headers`

---

### Task 5: GmailSyncPlanner + GmailSettings/GmailSyncState stores

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailSyncPlanner.swift`
- Create: `Sources/MustardKit/Gmail/GmailSettings.swift`
- Test: `Tests/MustardTests/GmailSyncPlannerTests.swift`, `Tests/MustardTests/GmailSettingsTests.swift`

- [ ] **Step 1: Failing tests** — `GmailSyncPlannerTests.swift`:

```swift
import XCTest
@testable import MustardKit

final class GmailSyncPlannerTests: XCTestCase {
    func testNewIDsFiltersSeenKeepsOrderAndCaps() {
        let ids = GmailSyncPlanner.newIDs(listed: ["m5", "m4", "m3", "m2", "m1"],
                                          seen: ["m4", "m1"], limit: 2)
        XCTAssertEqual(ids, ["m5", "m3"])
    }

    func testNewIDsEmptyWhenAllSeen() {
        XCTAssertEqual(GmailSyncPlanner.newIDs(listed: ["a"], seen: ["a"], limit: 10), [])
    }

    func testUpdatedSeenAppendsAndCapsKeepingMostRecent() {
        let seen = GmailSyncPlanner.updatedSeen(["a", "b", "c"], adding: ["d", "e"], cap: 4)
        XCTAssertEqual(seen, ["b", "c", "d", "e"])
    }

    func testUpdatedSeenDeduplicatesReprocessedIDs() {
        XCTAssertEqual(GmailSyncPlanner.updatedSeen(["a", "b"], adding: ["b", "c"], cap: 10),
                       ["a", "b", "c"])
    }
}
```

`GmailSettingsTests.swift` (injected `UserDefaults` suite, pinned dates):

```swift
import XCTest
@testable import MustardKit

final class GmailSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "GmailSettingsTests")!
        defaults.removePersistentDomain(forName: "GmailSettingsTests")
    }

    func testDefaults() {
        let s = GmailSettingsStore.load(defaults)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.labelId, "INBOX")
        XCTAssertEqual(s.query, "newer_than:3d")
        XCTAssertEqual(s.pollIntervalMinutes, 5)
    }

    func testRoundTrip() {
        var s = GmailSettingsStore.load(defaults)
        s.enabled = true
        s.labelId = "Label_7"
        s.pollIntervalMinutes = 10
        GmailSettingsStore.save(s, to: defaults)
        XCTAssertEqual(GmailSettingsStore.load(defaults), s)
    }

    func testIsDue() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(GmailSettings.isDue(lastPolledAt: nil, intervalMinutes: 5, now: now))
        XCTAssertFalse(GmailSettings.isDue(lastPolledAt: now.addingTimeInterval(-299), intervalMinutes: 5, now: now))
        XCTAssertTrue(GmailSettings.isDue(lastPolledAt: now.addingTimeInterval(-300), intervalMinutes: 5, now: now))
        XCTAssertFalse(GmailSettings.isDue(lastPolledAt: nil, intervalMinutes: 0, now: now))
    }

    func testSyncStateRoundTripAndDefault() {
        XCTAssertEqual(GmailSyncStateStore.load(defaults), GmailSyncState())
        var state = GmailSyncState()
        state.seenEventIDs = ["m1", "m2"]
        state.lastPolledAt = Date(timeIntervalSince1970: 1_780_000_000)
        GmailSyncStateStore.save(state, to: defaults)
        XCTAssertEqual(GmailSyncStateStore.load(defaults), state)
    }
}
```

- [ ] **Step 2:** `swift test --filter "GmailSyncPlannerTests|GmailSettingsTests" 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 3: Implement** `GmailSyncPlanner.swift`:

```swift
import Foundation

/// Decides which listed message ids still need fetching, and maintains the
/// bounded seen-set. Pure — the idempotency layer that keeps a 5-minute poll
/// from re-triaging (and re-paying a claude run for) the same emails, including
/// ones triage judged as noise and dropped.
public enum GmailSyncPlanner {
    /// Keep Gmail's newest-first order, drop already-seen ids, cap the batch.
    /// Leftovers beyond `limit` stay unseen and surface on the next poll.
    public static func newIDs(listed: [String], seen: Set<String>, limit: Int) -> [String] {
        Array(listed.filter { !seen.contains($0) }.prefix(limit))
    }

    /// Append processed ids, keeping at most `cap` of the most recent entries.
    public static func updatedSeen(_ seen: [String], adding: [String], cap: Int) -> [String] {
        var out = seen.filter { !adding.contains($0) } + adding
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }
}
```

`GmailSettings.swift`:

```swift
import Foundation

/// User-facing Gmail source configuration. Non-secret → UserDefaults as a
/// Codable blob (the `SourceSettingsStore` pattern; ADR-0001 defers a SwiftData
/// settings model). Tokens/credentials live in the Keychain, never here.
public struct GmailSettings: Codable, Equatable {
    public var enabled: Bool
    /// Gmail label id to poll (system ids like "INBOX" or user "Label_…" ids).
    public var labelId: String
    /// Extra Gmail search query (same syntax as the search bar); bounds the window.
    public var query: String
    public var pollIntervalMinutes: Double

    public init(enabled: Bool = false, labelId: String = "INBOX",
                query: String = "newer_than:3d", pollIntervalMinutes: Double = 5) {
        self.enabled = enabled
        self.labelId = labelId
        self.query = query
        self.pollIntervalMinutes = pollIntervalMinutes
    }

    /// Poll due-check for the 60s scheduler tick. Interval 0 means off.
    public static func isDue(lastPolledAt: Date?, intervalMinutes: Double, now: Date) -> Bool {
        guard intervalMinutes > 0 else { return false }
        guard let last = lastPolledAt else { return true }
        return now.timeIntervalSince(last) >= intervalMinutes * 60
    }
}

public enum GmailSettingsStore {
    public static let key = "gmailSettings"

    public static func load(_ defaults: UserDefaults = .standard) -> GmailSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(GmailSettings.self, from: data) else {
            return GmailSettings()
        }
        return s
    }

    public static func save(_ settings: GmailSettings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

/// Poll runtime state: the bounded seen-id set plus the last poll stamp.
/// Separate from `GmailSettings` so config edits never clobber sync progress.
public struct GmailSyncState: Codable, Equatable {
    public var seenEventIDs: [String]
    public var lastPolledAt: Date?

    public init(seenEventIDs: [String] = [], lastPolledAt: Date? = nil) {
        self.seenEventIDs = seenEventIDs
        self.lastPolledAt = lastPolledAt
    }
}

public enum GmailSyncStateStore {
    public static let key = "gmailSyncState"

    public static func load(_ defaults: UserDefaults = .standard) -> GmailSyncState {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(GmailSyncState.self, from: data) else {
            return GmailSyncState()
        }
        return s
    }

    public static func save(_ state: GmailSyncState, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}
```

- [ ] **Step 4:** `swift test --filter "GmailSyncPlannerTests|GmailSettingsTests" 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5: Commit** `feat(gmail): sync planner and settings/sync-state stores`

---

### Task 6: GmailTriage (prompt + parse-and-join + routing helpers)

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailTriage.swift`
- Test: `Tests/MustardTests/GmailTriageTests.swift`

- [ ] **Step 1: Failing tests:**

```swift
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
```

- [ ] **Step 2:** `swift test --filter GmailTriageTests 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 3: Implement:**

```swift
import Foundation

/// Prompt + parser for in-app Gmail triage (ADR-0012). The judgement the retired
/// scout routine made in a connected session now runs through headless `claude -p`:
/// only Gmail *access* needed a connector (ADR-0007) — the email bodies are
/// embedded in the prompt, and grounding reads the local KBs because the run's
/// cwd is the KB folders' common parent. Provenance (ids, thread, URL, labels,
/// date) always comes from OUR fetch — model output is joined back by id and
/// never trusted for identity.
public enum GmailTriage {
    public struct ProjectRoute: Equatable, Sendable {
        public let name: String
        public let workingDirectory: String
        public init(name: String, workingDirectory: String) {
            self.name = name
            self.workingDirectory = workingDirectory
        }
    }

    public struct EmailContext: Equatable, Sendable {
        public let message: GmailMessage
        /// Human label names resolved from labelIds — ground truth for `SourceClassifier`.
        public let labels: [String]
        public init(message: GmailMessage, labels: [String]) {
            self.message = message
            self.labels = labels
        }
    }

    public enum ParseOutcome: Equatable {
        case proposals([SourceProposal])
        case unparseable
    }

    static let maxBodyChars = 4000

    /// Enabled vault sources are the routing targets (their KBs are the grounding).
    public static func routes(from settings: SourceSettings) -> [ProjectRoute] {
        settings.sources
            .filter { $0.id == .vault && $0.enabled && !$0.workingDirectory.isEmpty }
            .map { ProjectRoute(name: $0.project, workingDirectory: $0.workingDirectory) }
    }

    /// claude runs in the common parent of the KB folders so grounding can read
    /// any project's notes (mirrors the scout's cross-KB access).
    public static func groundingDirectory(for routes: [ProjectRoute]) -> String? {
        guard let first = routes.first else { return nil }
        return URL(fileURLWithPath: first.workingDirectory).deletingLastPathComponent().path
    }

    public static func prompt(emails: [EmailContext], projects: [ProjectRoute]) -> String {
        let projectList = projects.map { route in
            "  • \(route.name) — notes in ./\(URL(fileURLWithPath: route.workingDirectory).lastPathComponent)/"
        }.joined(separator: "\n")

        let emailBlocks = emails.map { e -> String in
            let m = e.message
            let body = String((m.body.isEmpty ? m.snippet : m.body).prefix(maxBodyChars))
            return """
            --- EMAIL sourceEventID=\(m.id) threadID=\(m.threadId)
            From: \(m.from)
            Subject: \(m.subject)
            Date: \(m.date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")
            Labels: \(e.labels.joined(separator: ", "))
            \(body)
            """
        }.joined(separator: "\n\n")

        return """
        You are triaging Leon Baker's (leon@codeheroes.com.au) work inbox. Below are NEW emails
        fetched from Gmail. Decide which need Leon's attention, route each kept email to ONE
        project, ground it against that project's notes (search the project folders below from
        the current directory), and propose one recommendation per kept email. You NEVER send,
        reply, or file anything — drafts only, for review. DO NOT SEND anything.

        WHAT TO KEEP vs DROP — the core judgement, NOT a domain list:
          KEEP — needs Leon to do something on a project:
            • direct human emails from project contacts,
            • platform / operational mail about a project's app or delivery — Apple (App Store
              Connect, App Review, certificates, TestFlight), Google Play Console, RevenueCat,
              Firebase / Crashlytics, SDK/vendor delivery, support/enrolment cases,
            • Jira / Shortcut notifications directed at Leon (assigned, mentioned, review
              requested, comment, status change).
          DROP — noise:
            • newsletters, marketing, product promos/announcements (unless action-required),
              sales outreach, social notifications, automated digests, no-action receipts.
          When unsure: KEEP only if a human would need to act; otherwise drop.

        PROJECTS (route each kept email to exactly ONE "project" name from this list; if a kept
        email clearly belongs to none of them, drop it):
        \(projectList)

        ACTION for each kept email — pick ONE token:
        draft_email, draft_slack, create_task, ticket_write, vault_note, fyi, ignore.
        Ticket vs task: ticket_write = DRAFTING A NEW ticket/story. If the email asks Leon to
        check / verify / confirm / review / reply about an EXISTING ticket, use create_task or
        draft_email — never ticket_write.

        EMAILS:
        \(emailBlocks)

        Respond with ONLY a JSON array — one object per KEPT email, omit dropped emails, [] if
        none are worth keeping. "sourceEventID" must be copied verbatim from the email's header
        line. EXACT shape, confidence is a number, no prose:
        [{"sourceEventID": "<id>", "project": "<project name from the list>",
          "title": "short imperative title", "body": "1-3 sentences: what and why",
          "action_type": "draft_email", "confidence": 0.0,
          "reasoning": "one line: evidence used",
          "draft": "proposed content, e.g. a draft reply — DO NOT SEND IT"}]
        """
    }

    /// Join model output back to the fetched emails. Entries with an unknown
    /// sourceEventID or project are dropped — identity is never model-authored.
    public static func parseOutcome(
        _ text: String, emails: [EmailContext], projects: [ProjectRoute]
    ) -> ParseOutcome {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end,
              let raw = try? JSONSerialization.jsonObject(
                  with: Data(String(text[start...end]).utf8)) as? [[String: Any]] else {
            return .unparseable
        }
        let byID = Dictionary(emails.map { ($0.message.id, $0) }, uniquingKeysWith: { a, _ in a })
        let routeNames = Set(projects.map(\.name))
        let proposals = raw.compactMap { item -> SourceProposal? in
            guard let id = item["sourceEventID"] as? String, let email = byID[id],
                  let project = item["project"] as? String, routeNames.contains(project),
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let m = email.message
            let confidence = (item["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            return SourceProposal(
                source: .gmail, project: project,
                sourceItemID: m.threadId, sourceEventID: m.id,
                sourceContext: [m.from, m.subject].filter { !$0.isEmpty }.joined(separator: " · "),
                sourceURL: "https://mail.google.com/mail/u/0/#all/\(m.id)",
                occurredAt: m.date,
                title: title,
                body: item["body"] as? String ?? "",
                actionType: item["action_type"] as? String ?? "fyi",
                originalSource: String((m.body.isEmpty ? m.snippet : m.body).prefix(maxBodyChars)),
                confidence: min(max(confidence, 0), 1),
                reasoning: item["reasoning"] as? String ?? "",
                draft: item["draft"] as? String ?? "",
                labels: email.labels)
        }
        return .proposals(proposals)
    }
}
```

- [ ] **Step 4:** `swift test --filter GmailTriageTests 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5: Commit** `feat(gmail): triage prompt and provenance-safe parser`

---

### Task 7: AgentService.ingestExternal

**Files:**
- Modify: `Sources/MustardKit/Agent/AgentService.swift` (after `ingestInbox`, ~line 377)
- Test: `Tests/MustardTests/AgentServiceIngestExternalTests.swift`

- [ ] **Step 1: Failing test.** Look at an existing `AgentService` test file first (e.g. the one covering `ingestInbox` or sweeps) and copy its in-memory container + stubbed-`ClaudeRun` construction idiom exactly. The test:

```swift
import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class AgentServiceIngestExternalTests: XCTestCase {
    private func makeAgent() throws -> (AgentService, ModelContext) {
        let schema = Schema([Area.self, TaskList.self, MustardTask.self, Recommendation.self,
                             OutputCard.self, CalendarEvent.self, NoteIndexEntry.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let agent = AgentService(context: context, claude: { _, _ in
            ClaudeResult(ok: true, text: "[]")
        })
        return (agent, context)
    }

    private func proposal(event: String) -> SourceProposal {
        SourceProposal(source: .gmail, project: "DL-Knowledge-Base",
                       sourceItemID: "t1", sourceEventID: event,
                       title: "Reply to Ana", actionType: "draft_email",
                       confidence: 0.9, draft: "Hi Ana")
    }

    func testIngestExternalInsertsAndStampsProvenance() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([proposal(event: "m1")], vaultPath: "/kb/DL-Knowledge-Base")
        let recs = try context.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.source, "gmail")
        XCTAssertEqual(recs.first?.sourceEventID, "m1")
        XCTAssertEqual(recs.first?.vaultPath, "/kb/DL-Knowledge-Base")
    }

    func testIngestExternalDeduplicatesByEventID() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([proposal(event: "m1")], vaultPath: "/kb")
        await agent.ingestExternal([proposal(event: "m1"), proposal(event: "m2")], vaultPath: "/kb")
        let recs = try context.fetch(FetchDescriptor<Recommendation>())
        XCTAssertEqual(recs.count, 2)
    }

    func testIngestExternalEmptyIsANoOp() async throws {
        let (agent, context) = try makeAgent()
        await agent.ingestExternal([], vaultPath: "/kb")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recommendation>()).count, 0)
    }
}
```

(If the schema list above doesn't match how existing AgentService tests build their container — some use `MustardContainer` or a shared helper — use the repo's existing helper instead; the assertions stay.)

- [ ] **Step 2:** `swift test --filter AgentServiceIngestExternalTests 2>&1; echo EXIT:$?` — expect compile failure (`ingestExternal` missing).
- [ ] **Step 3: Implement** — in `AgentService.swift`, directly after `ingestInbox`:

```swift
    /// Ingest proposals produced in-process (the Gmail poll — ADR-0012) through
    /// the same normalize → dedupe → insert pipeline as the file-based sources,
    /// then apply trust. vaultPath = the routed project's KB folder, so keep /
    /// execution / export behave exactly like scout-era recs.
    public func ingestExternal(_ proposals: [SourceProposal], vaultPath: String) async {
        guard !proposals.isEmpty else { return }
        ingest(proposals, vaultPath: vaultPath)
        await applyTrust(Self.storedTrust())
    }
```

- [ ] **Step 4:** `swift test --filter AgentServiceIngestExternalTests 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5: Commit** `feat(agent): ingestExternal seam for in-process sources`

---

### Task 8: GmailService

**Files:**
- Create: `Sources/MustardKit/Gmail/GmailService.swift`
- Test: `Tests/MustardTests/GmailServiceTests.swift`

- [ ] **Step 1: Failing tests.** Read `Tests/MustardTests/GoogleCalendarServiceTests.swift` first and mirror its factory style. The Gmail version needs a scripted transport (routes by URL path) and a scripted claude:

```swift
import XCTest
@testable import MustardKit

@MainActor
final class GmailServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let routes = [GmailTriage.ProjectRoute(name: "DL-Knowledge-Base",
                                                   workingDirectory: "/kb/DL-Knowledge-Base")]

    private func messageJSON(id: String) -> String {
        let body = Data("please review".utf8).base64URLEncodedString()
        return """
        {"id":"\(id)","threadId":"t-\(id)","labelIds":["INBOX"],"internalDate":"1780000000000",
         "payload":{"mimeType":"text/plain","body":{"data":"\(body)"},
           "headers":[{"name":"From","value":"ana@tmr.qld.gov.au"},
                      {"name":"Subject","value":"DLA build"},
                      {"name":"Message-ID","value":"<\(id)@x>"}]}}
        """
    }

    /// Transport scripted by URL substring → (json, status).
    private func transport(_ table: @escaping @Sendable (URLRequest) -> (String, Int)) -> HTTPTransport {
        { req in let (json, status) = table(req); return (Data(json.utf8), status) }
    }

    private func makeService(
        transport: @escaping HTTPTransport,
        claude: @escaping ClaudeRun = { _, _ in ClaudeResult(ok: true, text: "[]") },
        ingest: @escaping @MainActor ([SourceProposal], String) async -> Void = { _, _ in },
        defaults: UserDefaults
    ) -> (GmailService, InMemoryTokenStore) {
        let store = InMemoryTokenStore()
        try? store.saveToken(GoogleToken(accessToken: "tok", refreshToken: "r",
                                         expiresAt: now.addingTimeInterval(3600)))
        try? store.saveCredentials(GoogleCredentials(clientId: "i", clientSecret: "s"))
        let service = GmailService(
            authSession: GoogleAuthSession(
                makeServer: { StubRedirectServer(port: 7777, result: RedirectResult(code: "c", state: "s")) },
                tokenClient: GoogleTokenClient(transport: { _ in (Data(), 500) }),
                store: store, openURL: { _ in }, scope: GmailService.scope,
                makePKCE: { PKCE(verifier: "v") }, makeState: { "s" }),
            tokenClient: GoogleTokenClient(transport: { _ in (Data(), 500) }),
            client: GmailClient(transport: transport),
            store: store,
            claude: claude,
            executionGate: AgentExecutionGate(),
            ingest: ingest,
            defaults: defaults,
            now: { self.now })
        service.bootstrap()
        return (service, store)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        var settings = GmailSettings()
        settings.enabled = true
        GmailSettingsStore.save(settings, to: d)
        return d
    }

    func testBootstrapReflectsStoredToken() {
        let d = makeDefaults("gmail-boot")
        let (service, store) = makeService(transport: transport { _ in ("{}", 200) }, defaults: d)
        XCTAssertEqual(service.state, .connected)
        try? store.clearToken()
        service.bootstrap()
        XCTAssertEqual(service.state, .disconnected)
    }

    func testPollIngestsKeptProposalsAndMarksSeen() async {
        let d = makeDefaults("gmail-poll")
        var ingested: [SourceProposal] = []
        var ingestedPath = ""
        let claudeOut = """
        [{"sourceEventID": "m1", "project": "DL-Knowledge-Base", "title": "Reply to Ana",
          "action_type": "draft_email", "confidence": 0.9, "draft": "Hi"}]
        """
        let (service, _) = makeService(
            transport: transport { req in
                let path = req.url!.path
                if path.hasSuffix("/messages") { return (#"{"messages":[{"id":"m1"}]}"#, 200) }
                if path.hasSuffix("/labels") { return (#"{"labels":[{"id":"INBOX","name":"INBOX"}]}"#, 200) }
                if path.contains("/messages/m1") { return (self.messageJSON(id: "m1"), 200) }
                return ("{}", 404)
            },
            claude: { _, cwd in
                XCTAssertEqual(cwd, "/kb")   // grounding dir = common parent
                return ClaudeResult(ok: true, text: claudeOut)
            },
            ingest: { proposals, path in ingested = proposals; ingestedPath = path },
            defaults: d)

        await service.poll(projects: routes)

        XCTAssertEqual(ingested.count, 1)
        XCTAssertEqual(ingested.first?.sourceEventID, "m1")
        XCTAssertEqual(ingestedPath, "/kb/DL-Knowledge-Base")
        XCTAssertEqual(GmailSyncStateStore.load(d).seenEventIDs, ["m1"])
        XCTAssertNotNil(service.lastPolled)
    }

    func testPollSkipsSeenIDsWithoutClaudeRun() async {
        let d = makeDefaults("gmail-seen")
        var state = GmailSyncState()
        state.seenEventIDs = ["m1"]
        GmailSyncStateStore.save(state, to: d)
        var claudeRan = false
        let (service, _) = makeService(
            transport: transport { req in
                req.url!.path.hasSuffix("/messages") ? (#"{"messages":[{"id":"m1"}]}"#, 200) : ("{}", 200)
            },
            claude: { _, _ in claudeRan = true; return ClaudeResult(ok: true, text: "[]") },
            defaults: d)
        await service.poll(projects: routes)
        XCTAssertFalse(claudeRan)
        XCTAssertEqual(service.lastPollSummary, "No new mail.")
    }

    func testPollFailedClaudeLeavesIDsUnseenForRetry() async {
        let d = makeDefaults("gmail-fail")
        let (service, _) = makeService(
            transport: transport { req in
                let path = req.url!.path
                if path.hasSuffix("/messages") { return (#"{"messages":[{"id":"m1"}]}"#, 200) }
                if path.hasSuffix("/labels") { return (#"{"labels":[]}"#, 200) }
                if path.contains("/messages/m1") { return (self.messageJSON(id: "m1"), 200) }
                return ("{}", 404)
            },
            claude: { _, _ in ClaudeResult(ok: false, text: "boom") },
            defaults: d)
        await service.poll(projects: routes)
        XCTAssertTrue(GmailSyncStateStore.load(d).seenEventIDs.isEmpty)
        XCTAssertEqual(service.lastPollSummary, "Triage failed: boom")
    }

    func testPollDisabledOrDisconnectedIsANoOp() async {
        let d = UserDefaults(suiteName: "gmail-off")!
        d.removePersistentDomain(forName: "gmail-off")   // default settings: disabled
        var touched = false
        let (service, _) = makeService(transport: transport { _ in touched = true; return ("{}", 200) },
                                       defaults: d)
        await service.poll(projects: routes)
        XCTAssertFalse(touched)
    }

    func testPoll401ClearsTokenAndDisconnects() async {
        let d = makeDefaults("gmail-401")
        let (service, store) = makeService(transport: transport { _ in ("{}", 401) }, defaults: d)
        await service.poll(projects: routes)
        XCTAssertEqual(service.state, .disconnected)
        XCTAssertNil((try? store.loadToken()) ?? nil)
    }

    func testPollSkipsWhenExecutionGateIsBusy() async {
        let d = makeDefaults("gmail-gate")
        var claudeRan = false
        let (service, _) = makeService(
            transport: transport { req in
                let path = req.url!.path
                if path.hasSuffix("/messages") { return (#"{"messages":[{"id":"m1"}]}"#, 200) }
                if path.hasSuffix("/labels") { return (#"{"labels":[]}"#, 200) }
                if path.contains("/messages/m1") { return (self.messageJSON(id: "m1"), 200) }
                return ("{}", 404)
            },
            claude: { _, _ in claudeRan = true; return ClaudeResult(ok: true, text: "[]") },
            defaults: d)
        _ = service.executionGateForTesting.tryAcquire(owner: "someone else")
        await service.poll(projects: routes)
        XCTAssertFalse(claudeRan)
        XCTAssertTrue(GmailSyncStateStore.load(d).seenEventIDs.isEmpty)
    }

    func testSendReplyThreadsOntoOriginal() async {
        let d = makeDefaults("gmail-send")
        var sendBody: [String: Any]?
        let (service, _) = makeService(
            transport: transport { req in
                let path = req.url!.path
                if path.contains("/messages/send") {
                    sendBody = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]
                    return (#"{"id":"sent1"}"#, 200)
                }
                if path.contains("/messages/m1") { return (self.messageJSON(id: "m1"), 200) }
                return ("{}", 404)
            }, defaults: d)
        let ok = await service.sendReply(toMessageID: "m1", body: "On it.")
        XCTAssertTrue(ok)
        XCTAssertEqual(sendBody?["threadId"] as? String, "t-m1")
        let raw = sendBody?["raw"] as? String ?? ""
        let mime = GmailParser.decodeBase64URL(raw).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(mime.contains("To: ana@tmr.qld.gov.au"))
        XCTAssertTrue(mime.contains("Subject: Re: DLA build"))
        XCTAssertTrue(mime.contains("In-Reply-To: <m1@x>"))
    }

    func testArchiveFailureSurfacesError() async {
        let d = makeDefaults("gmail-arch")
        let (service, _) = makeService(transport: transport { _ in ("{}", 500) }, defaults: d)
        let ok = await service.archive(messageID: "m1")
        XCTAssertFalse(ok)
        XCTAssertNotNil(service.lastActionError)
    }
}
```

- [ ] **Step 2:** `swift test --filter GmailServiceTests 2>&1; echo EXIT:$?` — expect compile failure.
- [ ] **Step 3: Implement** `Sources/MustardKit/Gmail/GmailService.swift`:

```swift
import Foundation
import Observation

/// Mustard-owned Gmail inbox (ADR-0012): OAuth via the shared Google stack,
/// polling discovery via `GmailClient` + `GmailTriage` (headless claude behind
/// the shared execution gate), and explicit actions (archive / reply) via the
/// Gmail API. Mirrors `GoogleCalendarService`'s shape. SwiftData-free: the
/// injected `ingest` closure inserts recommendations, so the service stays
/// platform-portable and unit-testable.
@MainActor
@Observable
public final class GmailService {
    public enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    /// Read + archive + send. `gmail.modify` alone covers read/archive, but the
    /// spec pins all three explicitly — self-documenting on the consent screen.
    public static let scope = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
    ].joined(separator: " ")
    public static let keychainService = "com.mustard.gmail"

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var lastPolled: Date?
    public private(set) var lastPollSummary: String?
    public private(set) var lastActionError: String?

    private let authSession: GoogleAuthSession
    private let tokenClient: GoogleTokenClient
    private let client: GmailClient
    private let store: TokenStore
    private let claude: ClaudeRun
    private let executionGate: AgentExecutionGate
    private let ingest: @MainActor ([SourceProposal], String) async -> Void
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Single-flight refresh, same rationale as GoogleCalendarService.
    private var refreshTask: Task<Void, Error>?

    static let batchLimit = 12
    static let listLimit = 25
    static let seenCap = 500

    public init(authSession: GoogleAuthSession, tokenClient: GoogleTokenClient,
                client: GmailClient, store: TokenStore,
                claude: @escaping ClaudeRun, executionGate: AgentExecutionGate,
                ingest: @escaping @MainActor ([SourceProposal], String) async -> Void,
                defaults: UserDefaults = .standard,
                now: @escaping () -> Date = { .now }) {
        self.authSession = authSession
        self.tokenClient = tokenClient
        self.client = client
        self.store = store
        self.claude = claude
        self.executionGate = executionGate
        self.ingest = ingest
        self.defaults = defaults
        self.now = now
    }

    /// Test seam only — lets tests occupy the gate without reaching into privates.
    var executionGateForTesting: AgentExecutionGate { executionGate }

    public func bootstrap() {
        state = ((try? store.loadToken()) ?? nil) != nil ? .connected : .disconnected
    }

    public func savedCredentials() -> GoogleCredentials? {
        (try? store.loadCredentials()) ?? nil
    }

    public func connect(credentials: GoogleCredentials) async {
        state = .connecting
        do {
            _ = try await authSession.connect(credentials: credentials)
            state = .connected
        } catch {
            state = .failed(GoogleCalendarService.message(for: error))
        }
    }

    public func disconnect() {
        try? store.clearToken()
        state = .disconnected
    }

    public func refreshIfNeeded() async throws {
        if let inFlight = refreshTask {
            try await inFlight.value
            return
        }
        guard let token = try store.loadToken(),
              let creds = try store.loadCredentials() else { throw GoogleAuthError.invalidGrant }
        guard let refresh = token.refreshToken else { return }
        guard token.expiresAt.timeIntervalSince(now()) <= 60 else { return }

        let task = Task { [tokenClient, store] in
            let fresh = try await tokenClient.refresh(refreshToken: refresh, credentials: creds)
            try store.saveToken(fresh)
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    /// One poll: list → diff vs seen → fetch new → claude triage → ingest per
    /// project → mark seen. Ids are marked seen ONLY after a successful triage
    /// parse, so failures retry on the next due poll.
    public func poll(projects: [GmailTriage.ProjectRoute]) async {
        let settings = GmailSettingsStore.load(defaults)
        guard settings.enabled, state == .connected else { return }
        // Stamp first so a persistently-failing poll retries on the interval,
        // not on every 60s scheduler tick (each retry is a claude run).
        lastPolled = now()
        guard let cwd = GmailTriage.groundingDirectory(for: projects) else {
            lastPollSummary = "Configure a knowledge-base source before polling Gmail."
            return
        }
        do {
            try await refreshIfNeeded()
            guard let token = try store.loadToken() else { state = .disconnected; return }
            let listed = try await client.listMessageIDs(
                accessToken: token.accessToken, labelId: settings.labelId,
                query: settings.query, maxResults: Self.listLimit)
            var sync = GmailSyncStateStore.load(defaults)
            let newIDs = GmailSyncPlanner.newIDs(
                listed: listed, seen: Set(sync.seenEventIDs), limit: Self.batchLimit)
            guard !newIDs.isEmpty else {
                sync.lastPolledAt = now()
                GmailSyncStateStore.save(sync, to: defaults)
                lastPollSummary = "No new mail."
                return
            }
            let labelNames = Dictionary(
                (try await client.fetchLabels(accessToken: token.accessToken)).map { ($0.id, $0.name) },
                uniquingKeysWith: { a, _ in a })
            var emails: [GmailTriage.EmailContext] = []
            for id in newIDs {
                let message = try await client.fetchMessage(accessToken: token.accessToken, id: id)
                emails.append(.init(message: message,
                                    labels: message.labelIds.compactMap { labelNames[$0] }))
            }
            // One claude subscription, one serial slot (ADR-0003) — respect the gate.
            guard let gateToken = executionGate.tryAcquire(owner: "gmail poll") else {
                lastPollSummary = "Agent busy — will retry next poll."
                return
            }
            let result = await claude(GmailTriage.prompt(emails: emails, projects: projects), cwd)
            executionGate.release(gateToken)
            guard result.ok else {
                lastPollSummary = "Triage failed: \(result.text)"
                return
            }
            switch GmailTriage.parseOutcome(result.text, emails: emails, projects: projects) {
            case .unparseable:
                lastPollSummary = "Triage returned output Mustard couldn't parse."
            case .proposals(let proposals):
                for route in projects {
                    let mine = proposals.filter { $0.project == route.name }
                    if !mine.isEmpty { await ingest(mine, route.workingDirectory) }
                }
                sync.seenEventIDs = GmailSyncPlanner.updatedSeen(
                    sync.seenEventIDs, adding: newIDs, cap: Self.seenCap)
                sync.lastPolledAt = now()
                GmailSyncStateStore.save(sync, to: defaults)
                lastPollSummary = "Kept \(proposals.count) of \(newIDs.count) new emails."
            }
        } catch GoogleAuthError.invalidGrant {
            try? store.clearToken()
            state = .disconnected
        } catch {
            // Transient network/server trouble: stay connected, surface it, retry
            // next interval — a poll loop must not park itself in .failed.
            lastPollSummary = "Poll failed: \(GoogleCalendarService.message(for: error))"
        }
    }

    /// Remove INBOX — never a delete. Failure lands on `lastActionError`.
    public func archive(messageID: String) async -> Bool {
        do {
            try await refreshIfNeeded()
            guard let token = try store.loadToken() else { state = .disconnected; return false }
            try await client.archive(accessToken: token.accessToken, id: messageID)
            lastActionError = nil
            return true
        } catch { return recordFailure(error) }
    }

    /// Reply in-thread: re-fetch the original for fresh headers (recipient,
    /// Message-ID, References, subject, threadId) — nothing model-authored goes
    /// into headers — build the MIME reply from the (edited) draft, send.
    public func sendReply(toMessageID: String, body: String) async -> Bool {
        do {
            try await refreshIfNeeded()
            guard let token = try store.loadToken() else { state = .disconnected; return false }
            let original = try await client.fetchMessage(accessToken: token.accessToken, id: toMessageID)
            let to = original.replyTo.isEmpty ? original.from : original.replyTo
            guard !to.isEmpty else {
                lastActionError = "Original message has no sender to reply to."
                return false
            }
            let mime = GmailMime.message(
                to: to,
                subject: GmailMime.replySubject(original.subject),
                body: body,
                inReplyTo: original.messageIdHeader,
                references: GmailMime.replyReferences(
                    parentReferences: original.references,
                    parentMessageID: original.messageIdHeader))
            _ = try await client.send(accessToken: token.accessToken,
                                      raw: Data(mime.utf8).base64URLEncodedString(),
                                      threadId: original.threadId)
            lastActionError = nil
            return true
        } catch { return recordFailure(error) }
    }

    /// For the Settings label picker. Errors surface as an empty list there.
    public func labels() async -> [GmailLabel] {
        do {
            try await refreshIfNeeded()
            guard let token = try store.loadToken() else { return [] }
            return try await client.fetchLabels(accessToken: token.accessToken)
        } catch { return [] }
    }

    private func recordFailure(_ error: Error) -> Bool {
        if case GoogleAuthError.invalidGrant = error {
            try? store.clearToken()
            state = .disconnected
        }
        lastActionError = GoogleCalendarService.message(for: error)
        return false
    }
}
```

Note: `GoogleCalendarService.message(for:)` is internal to MustardKit — callable here. If access control bites, hoist that function to a shared `GoogleErrorMessage.message(for:)` in `CalendarTypes.swift` and point both services at it.

- [ ] **Step 4:** `swift test --filter GmailServiceTests 2>&1; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 5:** Full suite: `swift test 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 6: Commit** `feat(gmail): polling triage service with explicit archive/reply actions`

---

### Task 9: App wiring (MustardApp + scheduler)

**Files:**
- Modify: `Sources/Mustard/MustardApp.swift`

No unit tests (app target; the decisions — `isDue`, `routes`, `groundingDirectory` — are already pure-tested). Build-verified.

- [ ] **Step 1:** In `MustardApp.init()` after the `calendar` construction (~line 170):

```swift
let gmailKeychain = KeychainTokenStore(service: GmailService.keychainService)
let gmail = GmailService(
    authSession: GoogleAuthSession(
        makeServer: { LoopbackRedirectServer() },
        tokenClient: GoogleTokenClient(),
        store: gmailKeychain,
        openURL: { NSWorkspace.shared.open($0) },
        scope: GmailService.scope),
    tokenClient: GoogleTokenClient(),
    client: GmailClient(),
    store: gmailKeychain,
    claude: ClaudeRunner.run,
    executionGate: executionGate,
    ingest: { proposals, vaultPath in
        await agent.ingestExternal(proposals, vaultPath: vaultPath)
    })
```

Add `@State private var gmail: GmailService` + `self._gmail = State(initialValue: gmail)`, pass `gmail: gmail` into `MustardAppScheduler`, and add `.environment(gmail)` alongside the existing `.environment(calendar)` on `RootView()`, and alongside `.environment(agent)` inside the `HoverPanelView` and `NotchView` content closures.

- [ ] **Step 2:** In `MustardAppScheduler`: add `private let gmail: GmailService` + init param; `gmail.bootstrap()` next to `calendar.bootstrap()` in `startIfNeeded()`; and inside `runSourceTick()`'s claude-gated block (`if !agent.isSweeping, ...`), after the `SourceSettingsStore.save(updated)` line:

```swift
let gmailSettings = GmailSettingsStore.load()
if gmailSettings.enabled, gmail.state == .connected,
   GmailSettings.isDue(lastPolledAt: gmail.lastPolled,
                       intervalMinutes: gmailSettings.pollIntervalMinutes, now: now) {
    await gmail.poll(projects: GmailTriage.routes(from: updated))
}
```

- [ ] **Step 3:** `swift build 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 4: Commit** `feat(gmail): wire GmailService into the app scheduler`

---

### Task 10: GmailSettingsView + Settings slot

**Files:**
- Create: `Sources/MustardKit/Views/GmailSettingsView.swift`
- Modify: `Sources/MustardKit/Views/SettingsView.swift:24` (insert `GmailSettingsView()` after `CalendarSettingsView()`)

Views render + dispatch only; build-verified (repo rule — never claim it "looks right").

- [ ] **Step 1: Implement** (mirrors `CalendarSettingsView`; Theme tokens only):

```swift
import SwiftUI

/// GMAIL inbox connection + polling config (ADR-0012). Credentials live in the
/// Keychain (its own service, separate from Calendar); non-secret settings in
/// `GmailSettingsStore`. Sending/archiving never happens from here — those are
/// explicit per-card actions in the Agent console.
struct GmailSettingsView: View {
    @Environment(GmailService.self) private var gmail
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var settings = GmailSettingsStore.load()
    @State private var labels: [GmailLabel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GMAIL")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if case .connected = gmail.state {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.done)
                }
            }

            switch gmail.state {
            case .disconnected, .failed:
                TextField("OAuth Client ID", text: $clientId)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                SecureField("OAuth Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                if case .failed(let msg) = gmail.state {
                    Text(msg).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
                }
                Button("Connect") {
                    Task {
                        await gmail.connect(
                            credentials: .init(clientId: clientId, clientSecret: clientSecret))
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google… approve in your browser.")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }

            case .connected:
                Toggle("Poll inbox for new mail", isOn: $settings.enabled)
                    .font(Theme.Fonts.meta)
                    .toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 8) {
                    Text("Label").font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    Picker("", selection: $settings.labelId) {
                        if !labels.contains(where: { $0.id == settings.labelId }) {
                            Text(settings.labelId).tag(settings.labelId)
                        }
                        ForEach(labels, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    Stepper(value: $settings.pollIntervalMinutes, in: 1...60, step: 1) {
                        Text("Every \(Int(settings.pollIntervalMinutes)) min")
                            .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                HStack(spacing: 14) {
                    Button("Poll now") {
                        Task {
                            await gmail.poll(projects: GmailTriage.routes(
                                from: SourceSettingsStore.loadOrMigrate()))
                        }
                    }
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.accent).buttonStyle(.plain)
                    Button("Disconnect", role: .destructive) { gmail.disconnect() }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.error).buttonStyle(.plain)
                }
                if let summary = gmail.lastPollSummary {
                    Text(summary).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .onAppear {
            if let creds = gmail.savedCredentials() {
                clientId = creds.clientId
                clientSecret = creds.clientSecret
            }
            settings = GmailSettingsStore.load()
        }
        .onChange(of: settings) { GmailSettingsStore.save(settings) }
        .task(id: gmail.state == .connected) {
            if gmail.state == .connected { labels = await gmail.labels() }
        }
    }
}
```

- [ ] **Step 2:** In `SettingsView.swift`, insert `GmailSettingsView()` on the line after `CalendarSettingsView()`.
- [ ] **Step 3:** `swift build 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 4: Commit** `feat(gmail): settings section with label picker and polling controls`

---

### Task 11: Gmail actions on the recommendation card

**Files:**
- Modify: `Sources/MustardKit/Views/RecommendationDetailView.swift`

Build-verified. Product law: Approve keeps its existing meaning; sending is a separate explicit click behind a confirmation; archive is remove-INBOX only.

- [ ] **Step 1:** Add to `RecommendationDetailView`:

```swift
@Environment(GmailService.self) private var gmail
@State private var confirmingSend = false
@State private var gmailActionRunning = false
```

Insert `gmailActions` into `body` between `drawer` and `outcomes`:

```swift
/// Explicit, per-card Gmail actions (ADR-0012). These are the ONLY paths that
/// touch the real mailbox — never Approve, never trust auto-approve.
@ViewBuilder private var gmailActions: some View {
    if rec.source == SourceID.gmail.rawValue,
       let messageID = rec.sourceEventID, !messageID.isEmpty,
       gmail.state == .connected {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if rec.action == .draftEmail {
                    Button("Send reply via Gmail") { confirmingSend = true }
                        .controlSize(.small).tint(Theme.Palette.accent)
                        .disabled(gmailActionRunning ||
                                  rec.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Sends the draft above as a reply on the original thread. Nothing sends without this click.")
                        .confirmationDialog("Send this reply via Gmail?",
                                            isPresented: $confirmingSend) {
                            Button("Send reply") { Task { await sendGmailReply(messageID) } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Replies on the original thread with the current draft.")
                        }
                }
                Button("Archive in Gmail") { Task { await archiveGmail(messageID) } }
                    .controlSize(.small)
                    .disabled(gmailActionRunning)
                    .help("Removes the email from your Gmail inbox (never deletes) and files this card.")
                Spacer()
            }
            if let error = gmail.lastActionError {
                Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
            }
        }
    }
}

private func sendGmailReply(_ messageID: String) async {
    gmailActionRunning = true
    defer { gmailActionRunning = false }
    guard await gmail.sendReply(toMessageID: messageID, body: rec.draft) else { return }
    agent.keep(rec)   // sent = handled: file to the inbox log, clear the card
}

private func archiveGmail(_ messageID: String) async {
    gmailActionRunning = true
    defer { gmailActionRunning = false }
    guard await gmail.archive(messageID: messageID) else { return }
    agent.keep(rec)
}
```

- [ ] **Step 2:** `swift build 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0. If the build fails because some preview/other surface renders `RecommendationDetailView` without a `GmailService` environment, check `#Preview` blocks and inject a stub there (`PreviewData.swift` pattern).
- [ ] **Step 3:** `swift test 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0 (guards against view-layer regressions in shared code).
- [ ] **Step 4: Commit** `feat(gmail): explicit send-reply and archive actions on gmail cards`

---

### Task 12: ADR-0012 + docs

**Files:**
- Create: `docs/adr/0012-mustard-owned-gmail-inbox.md`
- Modify: `docs/build-order.md` (append a completed F-entry describing the Gmail inbox, referencing the spec)
- Modify: `CLAUDE.md` (the "Out of scope (YAGNI)" line claiming email sources are "fields modelled, not wired" — amend to note the Gmail API source now exists per ADR-0012; add `Gmail/` to the folder-layout listing)

- [ ] **Step 1:** Write the ADR — follow the header/status style of `docs/adr/0008-local-only-email-scout.md`. Content: status Accepted; supersedes ADR-0008 for email *discovery* (the scout is retired once this is enabled; `InboxIngest`/`_recs/` remains as a legacy ingest path and the message-id dedupe makes the two idempotent against each other); implements ADR-0007's named fallback (A) Mustard-owned Gmail OAuth; decisions: polling not push, scopes readonly+modify+send, Keychain service `com.mustard.gmail`, triage via headless `claude -p` with embedded bodies + KB grounding (connector was only ever needed for *access*), send/archive are explicit per-card clicks and never auto-run; consequences: Mac-anchored like everything else (ADR-0003), first-run consent screen unverified-app warning, `gmail.send` makes token hygiene matter more (still Keychain-only).
- [ ] **Step 2:** `swift build 2>&1 | tail -3; echo EXIT:$?` (docs don't compile, but keep the habit) and commit `docs(gmail): ADR-0012, build-order entry, CLAUDE.md updates`

---

### Task 13: Verification + PR + merge

- [ ] **Step 1:** `swift test 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0; note the new total test count.
- [ ] **Step 2:** `swift build 2>&1 | tail -3; echo EXIT:$?` — expect EXIT:0.
- [ ] **Step 3:** `./build-ios.sh 2>&1 | tail -5; echo EXIT:$?` — expect EXIT:0 (all `Gmail/` files compile for iOS; no AppKit outside Views/).
- [ ] **Step 4:** Push branch (HTTPS remote), open PR to `main` titled `feat(gmail): Mustard-owned Gmail inbox (poll → triage → explicit act) — ADR-0012`, body summarizing spec/plan links, evidence, and Leon's post-merge activation steps. End body with the Claude Code attribution line.
- [ ] **Step 5:** Merge per repo policy (squash), append the digest entry to `.agent-loop/digest.md` with the `git revert <sha>` line.

---

## Self-review notes

- Spec coverage: fetch-by-label (Task 3 list + Task 5 settings), read content (Tasks 2–3), draft generation (Task 6 + existing pipeline via Task 7), archive (Tasks 3, 8, 11), send/reply with threading (Tasks 4, 8, 11), scopes (Task 1 + `GmailService.scope`), token storage + silent refresh (Task 8 + Keychain service), polling scheduler (Tasks 5, 9), label choice + interval + review-before-send resolutions (Tasks 5, 10, 11).
- Type consistency: `GmailTriage.ProjectRoute`/`EmailContext` used identically in Tasks 6, 8, 9, 10; `GmailService.poll(projects:)` everywhere; `rec.sourceEventID` is `String?` (checked against `Recommendation.swift`).
- Known adaptation points called out inline: `StubRedirectServer` init signature (Task 1/8), AgentService test-container idiom (Task 7), `message(for:)` access level (Task 8), previews needing a GmailService environment (Task 11).
