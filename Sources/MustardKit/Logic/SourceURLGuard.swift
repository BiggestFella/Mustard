import Foundation

/// Guards against a mismatched-host `sourceURL` — e.g. the scout sometimes writes a
/// Jira/Atlassian browse link into a Shortcut-sourced rec's `sourceURL`, which would
/// send the "Open" link to the wrong system. Pure + tested.
public enum SourceURLGuard {
    public static func guarded(source: SourceID, sourceURL: String?) -> String? {
        guard source == .shortcut,
              let raw = sourceURL,
              let host = URL(string: raw)?.host?.lowercased()
        else { return sourceURL }
        if host.contains("jira") || host.contains("atlassian") { return nil }
        return sourceURL
    }
}
