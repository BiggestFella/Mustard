import Foundation

/// Which source produced a proposal. String-backed so it maps cleanly onto
/// `Recommendation.source` (a String column) for dedupe.
public enum SourceID: String, Codable, CaseIterable, Sendable {
    case gmail
    case vault
    case jira
    case shortcut
    /// A push-to-talk voice capture (F25, ADR-0011) — recs the cleanup pass routes
    /// into triage carry this so the deck shows where they came from.
    case voice
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
    /// Gmail labels on the source thread (e.g. "Jira Updates", "Shortcut Notifications").
    /// Ground truth for `SourceClassifier`. Empty for vault sweeps and legacy recs.
    public let labels: [String]

    public init(
        source: SourceID, project: String = "", sourceItemID: String, sourceEventID: String,
        sourceContext: String = "", sourceURL: String? = nil, occurredAt: Date? = nil,
        title: String, body: String = "", actionType: String = "vault_note",
        originalSource: String? = nil,
        confidence: Double = 0.5, reasoning: String = "", draft: String = "",
        labels: [String] = []
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

    enum CodingKeys: String, CodingKey {
        case source, project, sourceItemID, sourceEventID, sourceContext
        case sourceURL, originalSource, occurredAt, title, body
        case actionType, confidence, reasoning, draft, labels
    }

    // Custom decode so `labels` (added later) defaults to `[]` when a rec JSON omits
    // it — legacy `_recs/*.json` files stay decodable. Other fields keep their prior
    // required/optional semantics. `encode(to:)` remains synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceID.self, forKey: .source)
        project = try c.decode(String.self, forKey: .project)
        sourceItemID = try c.decode(String.self, forKey: .sourceItemID)
        sourceEventID = try c.decode(String.self, forKey: .sourceEventID)
        sourceContext = try c.decode(String.self, forKey: .sourceContext)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        originalSource = try c.decodeIfPresent(String.self, forKey: .originalSource)
        occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        actionType = try c.decode(String.self, forKey: .actionType)
        confidence = try c.decode(Double.self, forKey: .confidence)
        reasoning = try c.decode(String.self, forKey: .reasoning)
        draft = try c.decode(String.self, forKey: .draft)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
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
            originalSource: originalSource, confidence: confidence, reasoning: reasoning,
            draft: draft, labels: labels
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
