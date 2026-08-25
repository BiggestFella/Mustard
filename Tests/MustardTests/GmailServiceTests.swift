import XCTest
@testable import MustardKit

@MainActor
final class GmailServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let routes = [GmailTriage.ProjectRoute(name: "DL-Knowledge-Base",
                                                   workingDirectory: "/kb/DL-Knowledge-Base")]

    private nonisolated func messageJSON(id: String) -> String {
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
        XCTAssertEqual(service.lastPollSummary, "Agent busy — will retry next poll.")
    }

    func testPollUnparseableTriageOutputLeavesIDsUnseen() async {
        let d = makeDefaults("gmail-unparseable")
        var ingestCalls = 0
        let (service, _) = makeService(
            transport: transport { req in
                let path = req.url!.path
                if path.hasSuffix("/messages") { return (#"{"messages":[{"id":"m1"}]}"#, 200) }
                if path.hasSuffix("/labels") { return (#"{"labels":[]}"#, 200) }
                if path.contains("/messages/m1") { return (self.messageJSON(id: "m1"), 200) }
                return ("{}", 404)
            },
            claude: { _, _ in ClaudeResult(ok: true, text: "sorry, here are my thoughts instead") },
            ingest: { _, _ in ingestCalls += 1 },
            defaults: d)
        await service.poll(projects: routes)
        XCTAssertEqual(ingestCalls, 0)
        XCTAssertTrue(GmailSyncStateStore.load(d).seenEventIDs.isEmpty)
        XCTAssertEqual(service.lastPollSummary, "Triage returned output Mustard couldn't parse.")
    }

    func testLabelsReturnsEmptyOnTransportFailure() async {
        let d = makeDefaults("gmail-labels-fail")
        let (service, _) = makeService(transport: transport { _ in ("boom", 500) }, defaults: d)
        let labels = await service.labels()
        XCTAssertEqual(labels, [])
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
