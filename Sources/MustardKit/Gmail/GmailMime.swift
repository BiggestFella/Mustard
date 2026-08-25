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

    /// Any CR/LF in a header value would start a forged header — truncate there
    /// so the injected content never reaches the output (a mid-line space would
    /// still leave the forged text present, just unbroken onto the prior line).
    static func sanitized(_ value: String) -> String {
        if let idx = value.firstIndex(where: { $0.isNewline }) {
            return String(value[..<idx])
        }
        return value
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
