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
