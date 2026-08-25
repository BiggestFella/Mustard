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
    /// Re-entrancy guard: a manual poll trigger while the scheduled loop's poll is
    /// still in flight must not race a second `claude` run against the same ids.
    /// @MainActor makes this a safe non-atomic guard.
    private var isPolling = false

    static let batchLimit = 12
    static let listLimit = 25
    static let seenCap = 500
    /// Give up on an id after this many failed/unparseable triage attempts (finding S3):
    /// a hostile or malformed email must not re-run claude on every poll forever.
    static let giveUpAfterFailures = 3

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
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
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
            defer { executionGate.release(gateToken) }
            let result = await claude(GmailTriage.prompt(emails: emails, projects: projects), cwd)
            guard result.ok else {
                let giveUp = GmailSyncPlanner.registerFailures(
                    &sync.failedAttempts, ids: newIDs, giveUpAt: Self.giveUpAfterFailures)
                sync.seenEventIDs = GmailSyncPlanner.updatedSeen(
                    sync.seenEventIDs, adding: giveUp, cap: Self.seenCap)
                sync.lastPolledAt = now()
                GmailSyncStateStore.save(sync, to: defaults)
                lastPollSummary = "Triage failed: \(String(result.text.prefix(200)))"
                return
            }
            switch GmailTriage.parseOutcome(result.text, emails: emails, projects: projects) {
            case .unparseable:
                let giveUp = GmailSyncPlanner.registerFailures(
                    &sync.failedAttempts, ids: newIDs, giveUpAt: Self.giveUpAfterFailures)
                sync.seenEventIDs = GmailSyncPlanner.updatedSeen(
                    sync.seenEventIDs, adding: giveUp, cap: Self.seenCap)
                sync.lastPolledAt = now()
                GmailSyncStateStore.save(sync, to: defaults)
                lastPollSummary = "Triage returned output Mustard couldn't parse."
            case .proposals(let proposals):
                for route in projects {
                    let mine = proposals.filter { $0.project == route.name }
                    if !mine.isEmpty { await ingest(mine, route.workingDirectory) }
                }
                for id in newIDs { sync.failedAttempts[id] = nil }
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

    /// Who a reply to `messageID` would go to — for the send-confirmation dialog
    /// (finding H5a), so Leon sees the recipient before confirming a send. Best-effort:
    /// nil on any fetch failure, letting the caller fall back to generic copy.
    public func replyRecipient(forMessageID messageID: String) async -> String? {
        do {
            try await refreshIfNeeded()
            guard let token = try store.loadToken() else { return nil }
            let original = try await client.fetchMessage(accessToken: token.accessToken, id: messageID)
            let to = original.replyTo.isEmpty ? original.from : original.replyTo
            return to.isEmpty ? nil : to
        } catch { return nil }
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
