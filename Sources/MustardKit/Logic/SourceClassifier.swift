import Foundation

/// Derives the *logical* source of a Gmail-delivered rec. Jira/Shortcut notifications
/// arrive over Gmail; the meaningful source is the system the notification is about.
/// Pure + tested. Only `gmail` is ever reclassified — vault/delegated/already-classified
/// transports pass through unchanged.
public enum SourceClassifier {
    /// Gmail label → logical source. Labels are ground truth: Jira/Shortcut robot mail
    /// is auto-filtered into these labels by a Gmail filter, whereas a human reply that
    /// merely *mentions* a ticket key is not — so labels must win over any content guess.
    public static func logicalSource(transport: SourceID, sourceContext: String, labels: [String] = []) -> SourceID {
        guard transport == .gmail else { return transport }
        if !labels.isEmpty {
            let normalized = Set(labels.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            if normalized.contains("jira") || normalized.contains("jira updates") { return .jira }
            if normalized.contains("shortcut notifications") { return .shortcut }
            // Labels are present but none matched — trust them over content, no fallback.
            return .gmail
        }
        // No labels available (older recs, or the scout didn't attach them): fall back
        // to the provenance text. "Gmail · Shortcut · <subject>" puts the token mid-string,
        // not as a prefix, so scan "·"-delimited segments rather than just the prefix.
        let segments = sourceContext.components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if segments.contains("jira") { return .jira }
        if segments.contains("shortcut") { return .shortcut }
        // Jira-style ticket key (e.g. DLA-5280) anywhere in the provenance → Jira.
        if sourceContext.range(of: #"[A-Z]{2,}-\d+"#, options: .regularExpression) != nil { return .jira }
        return .gmail
    }
}
