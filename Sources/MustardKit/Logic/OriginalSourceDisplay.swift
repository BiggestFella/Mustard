import Foundation

/// Pure presentation for the original-source block on triage surfaces (BAK-265).
/// Views only render; label, preview, and collapse live here so desktop + mobile
/// stay consistent and unit-tested.
public enum OriginalSourceDisplay {
    /// List-row / swipe-card preview — short enough not to dominate the card.
    public static let previewCharLimit = 180
    public static let previewLineLimit = 3
    /// Detail-sheet collapse threshold. Bodies at or under this stay fully visible.
    public static let collapsedCharLimit = 400
    public static let collapsedLineLimit = 8

    public static let emailLabel = "ORIGINAL EMAIL"
    public static let sourceLabel = "ORIGINAL SOURCE"

    /// True when the rec arrived over Gmail — including Jira/Shortcut mail whose
    /// logical `source` was rewritten by `IngestNormalizer` but whose permalink
    /// still marks the Gmail transport (`GmailTriage.isGmailSourced`).
    public static func isEmail(source: String, sourceURL: String?) -> Bool {
        source == SourceID.gmail.rawValue || GmailTriage.isGmailSourced(sourceURL)
    }

    /// "ORIGINAL EMAIL" for Gmail-sourced recs, "ORIGINAL SOURCE" otherwise.
    public static func sectionLabel(source: String, sourceURL: String?) -> String {
        isEmail(source: source, sourceURL: sourceURL) ? emailLabel : sourceLabel
    }

    public static func isPresent(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func preview(_ text: String) -> String {
        clipped(text, charLimit: previewCharLimit, lineLimit: previewLineLimit)
    }

    public static func isCollapsible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > collapsedCharLimit
            || lineCount(trimmed) > collapsedLineLimit
    }

    public static func collapsed(_ text: String) -> String {
        clipped(text, charLimit: collapsedCharLimit, lineLimit: collapsedLineLimit)
    }

    /// Returns a preview string, or nil when there is nothing to show.
    public static func previewText(_ originalSource: String?) -> String? {
        guard isPresent(originalSource), let originalSource else { return nil }
        return preview(originalSource)
    }

    private static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func clipped(_ text: String, charLimit: Int, lineLimit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var slice = trimmed
        if slice.count > charLimit {
            slice = String(slice.prefix(charLimit))
        }
        let lines = slice.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > lineLimit {
            slice = lines.prefix(lineLimit).joined(separator: "\n")
        }
        let clipped = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped == trimmed ? trimmed : clipped + "…"
    }
}
