import Foundation

/// Deterministic Mac-side normalization applied to every ingested `SourceProposal`
/// before dedupe: derive the logical source (Jira/Shortcut over the Gmail transport)
/// and demote routine Shortcut "PO Review" assignments to `ignore`. Pure + tested.
public enum IngestNormalizer {
    public static func normalize(_ p: SourceProposal) -> SourceProposal {
        let source = SourceClassifier.logicalSource(transport: p.source, sourceContext: p.sourceContext, labels: p.labels ?? [])
        let action = demotesToIgnore(source: source, title: p.title, sourceContext: p.sourceContext)
            ? "ignore" : p.actionType
        return p.reclassified(source: source, actionType: action)
            .withSourceURL(SourceURLGuard.guarded(source: source, sourceURL: p.sourceURL))
    }

    /// A Shortcut "PO Review" assignment is Leon's standing responsibility and needs no
    /// triage — demote it to `ignore`. Scoped to Shortcut so unrelated mentions are untouched.
    public static func demotesToIgnore(source: SourceID, title: String, sourceContext: String) -> Bool {
        guard source == .shortcut else { return false }
        return (title + " " + sourceContext).lowercased().contains("po review")
    }
}
