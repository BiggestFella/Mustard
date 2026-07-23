import Foundation

/// Which source produced a proposal. String-backed so it maps cleanly onto
/// `Recommendation.source` (a String column) for dedupe.
public enum SourceID: String, Codable, CaseIterable, Sendable {
    case gmail
    case vault
    case jira
    case shortcut
}

/// A source agent's output: a recommendation draft plus the provenance needed to
/// dedupe it. Pure value type. Produced by `VaultSweep` (local) and the cloud
/// scout's `_inbox/` files (ingested Mac-side).
public struct SourceProposal: Equatable, Sendable, Codable {
    public let source: SourceID
    /// Which project / knowledge base this belongs to (the KB folder name). Keeps
    /// dedupe and grounding isolated per project — identical note text in two KBs
    /// gets distinct identity, so one project's note can never collapse into another.
    public let project: String
    /// Durable parent object (email thread, or vault content hash).
    public let sourceItemID: String
    /// Triggering event (email message id, or deterministic vault content hash).
    public let sourceEventID: String
    public let sourceContext: String
    public let sourceURL: String?
    public let originalSource: String?
    public let occurredAt: Date?
    public let title: String
    public let body: String
    public let actionType: String
    public let confidence: Double
    public let reasoning: String
    public let draft: String
    /// Gmail thread labels (e.g. "Jira", "Shortcut Notifications"), when the scout
    /// attached them. Ground-truth source signal — see `SourceClassifier`.
    public let labels: [String]?

    public init(
        source: SourceID, project: String = "", sourceItemID: String, sourceEventID: String,
        sourceContext: String = "", sourceURL: String? = nil, occurredAt: Date? = nil,
        title: String, body: String = "", actionType: String = "vault_note",
        originalSource: String? = nil,
        confidence: Double = 0.5, reasoning: String = "", draft: String = "",
        labels: [String]? = nil
    ) {
        self.source = source
        self.project = project
        self.sourceItemID = sourceItemID
        self.sourceEventID = sourceEventID
        self.sourceContext = sourceContext
        self.sourceURL = sourceURL
        self.originalSource = originalSource
        self.occurredAt = occurredAt
        self.title = title
        self.body = body
        self.actionType = actionType
        self.confidence = confidence
        self.reasoning = reasoning
        self.draft = draft
        self.labels = labels
    }
}

public extension SourceProposal {
    /// Map a vault sweep proposal into a `SourceProposal`, deriving a **stable,
    /// project-qualified** content hash as its identity so (a) repeated scheduled
    /// sweeps don't duplicate unchanged suggestions, and (b) identical note text in
    /// two different KBs never collides in dedupe.
    init(vault p: VaultSweep.Proposal, project: String) {
        let hash = SourceProposal.stableHash("\(project)\n\(p.title)\n\(p.body)\n\(p.actionType)\n\(p.draft)")
        self.init(
            source: .vault, project: project, sourceItemID: hash, sourceEventID: hash,
            title: p.title, body: p.body, actionType: p.actionType,
            confidence: p.confidence, reasoning: p.reasoning, draft: p.draft
        )
    }

    /// A copy with the logical source and/or action overridden, everything else
    /// preserved. Used by `IngestNormalizer` to re-stamp the immutable proposal.
    func reclassified(source: SourceID, actionType: String) -> SourceProposal {
        SourceProposal(
            source: source, project: project, sourceItemID: sourceItemID,
            sourceEventID: sourceEventID, sourceContext: sourceContext, sourceURL: sourceURL,
            occurredAt: occurredAt, title: title, body: body, actionType: actionType,
            originalSource: originalSource, confidence: confidence, reasoning: reasoning, draft: draft,
            labels: labels
        )
    }

    /// A copy with only `sourceURL` overridden — used to drop a mismatched-host link
    /// (see `SourceURLGuard`) without disturbing anything else.
    func withSourceURL(_ sourceURL: String?) -> SourceProposal {
        SourceProposal(
            source: source, project: project, sourceItemID: sourceItemID,
            sourceEventID: sourceEventID, sourceContext: sourceContext, sourceURL: sourceURL,
            occurredAt: occurredAt, title: title, body: body, actionType: actionType,
            originalSource: originalSource, confidence: confidence, reasoning: reasoning, draft: draft,
            labels: labels
        )
    }

    /// Deterministic FNV-1a hash, hex-encoded. Process-stable across launches —
    /// unlike Swift's seeded `String.hashValue`, which must never key persisted
    /// dedupe identity.
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
