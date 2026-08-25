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
