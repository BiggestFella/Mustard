import Foundation

/// Pure resolver: turns an item's stored `sourceURL` (+ source string) into an
/// openable web link, or `nil`. The scheme allow-list (`http`/`https`) is a
/// security boundary — a `sourceURL` can come from the agent or an external
/// source, so we never let a `file:`/`javascript:`/other-scheme string drive a
/// load. Vault note paths (meeting tasks) have no scheme and are rejected.
public struct SourceLink: Equatable {
    public let url: URL
    /// The item's title — shown as the panel header text.
    public let label: String
    /// Lowercased raw source string (e.g. "shortcut", "jira", "gmail", "vault").
    public let sourceKind: String

    public init?(sourceURL: String?, source: String, title: String) {
        guard
            let raw = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        let kind = source.lowercased()
        // A Shortcut item's link must point at Shortcut. The scout sometimes synthesizes
        // a Jira `browse/DLA-xxxx` URL from a ticket key in the story title — distrust
        // that rather than open Jira for a Shortcut rec.
        if kind == "shortcut", let host = url.host?.lowercased(),
           host.contains("jira") || host.contains("atlassian") {
            return nil
        }
        self.url = url
        self.label = title
        self.sourceKind = kind
    }

    /// SF Symbol for the source glyph. Mirrors `SourceBadge` for gmail/vault and
    /// adds ticket-ish symbols for jira/shortcut (which `SourceBadge` can't map yet).
    public var symbol: String {
        switch sourceKind {
        case "shortcut": "checklist"
        case "jira": "ticket"
        case "gmail": "envelope.fill"
        case "vault": "books.vertical"
        default: "link"
        }
    }

    /// Typed source id for `SourceLogo`; unrecognised/default kinds fall back to `.vault`
    /// (the quiet, no-brand-mark case) since `.symbol`'s "link" default has no logo either.
    public var id: SourceID { SourceID(rawValue: sourceKind) ?? .vault }

    /// Friendly source name (header tooltip / accessibility).
    public var sourceName: String {
        switch sourceKind {
        case "shortcut": "Shortcut"
        case "jira": "Jira"
        case "gmail": "Gmail"
        case "vault": "Vault"
        default: "Source"
        }
    }
}

public extension SourceLink {
    init?(from rec: Recommendation) {
        self.init(sourceURL: rec.sourceURL, source: rec.source, title: rec.title)
    }

    init?(from task: MustardTask) {
        self.init(sourceURL: task.sourceURL, source: task.source, title: task.title)
    }
}
