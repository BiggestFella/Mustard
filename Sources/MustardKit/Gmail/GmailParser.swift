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

    /// Real emails nest 2–4 levels; the payload is sender-influenced data, so cap
    /// the walk rather than trusting the structure.
    private static let maxPartDepth = 16

    private static func firstPart(_ part: [String: Any], mime: String, depth: Int = 0) -> String? {
        guard depth < maxPartDepth else { return nil }
        if (part["mimeType"] as? String)?.caseInsensitiveCompare(mime) == .orderedSame,
           let body = part["body"] as? [String: Any],
           let dataString = body["data"] as? String,
           let data = decodeBase64URL(dataString),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        for sub in part["parts"] as? [[String: Any]] ?? [] {
            if let found = firstPart(sub, mime: mime, depth: depth + 1) { return found }
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
        // ReDoS guard: cap input before the regex passes run — an oversized hostile
        // HTML body must not blow out triage latency.
        var text = String(html.prefix(20_000))
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
        // Collapses ALL blank lines, including intentional paragraph gaps — by this
        // stage "</p><br> adjacency" and "deliberate blank line" are indistinguishable.
        // Acceptable for triage prompts; revisit tag-aware boundaries if readability suffers.
        text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
