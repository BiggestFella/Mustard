import Foundation

/// The read-only wire contract for Code Heroes' grouped decision-triage report.
/// It deliberately contains no filesystem or SwiftData dependency: source opening and
/// reconciliation are adapter responsibilities in a later task.
public enum CodeHeroesDecisionQueue {
    /// Versioned contract values which have been reviewed as read-only import modes.
    public static let approvedReadOnlyImportMarkers: Set<String> = ["future-adapter-only", "future-read-only-v2"]
    /// Stable projection identity grammar: an alphanumeric first character followed by
    /// alphanumerics, dots, underscores, or hyphens. Whitespace is never normalized.
    public static let clusterIDPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
    public struct Document: Codable, Equatable {
        public var schemaVersion: Int
        public var reportType: String
        public var generatedAt: String
        public var sourceRunID: String
        public var sourceReceipt: String
        public var canonicalInput: String
        public var readOnly: Bool
        public var decisionStatusMutations: Int
        public var mustardImport: String
        public var summary: [String: JSONValue]
        public var historicalOpenDecisionIDs: [String]
        public var historicalExclusions: [HistoricalExclusion]
        public var queue: [Cluster]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", reportType = "report_type", generatedAt = "generated_at"
            case sourceRunID = "source_run_id", sourceReceipt = "source_receipt", canonicalInput = "canonical_input"
            case readOnly = "read_only", decisionStatusMutations = "decision_status_mutations", mustardImport = "mustard_import"
            case summary, historicalOpenDecisionIDs = "historical_open_decision_ids"
            case historicalExclusions = "historical_exclusions", queue
        }
    }

    public struct HistoricalExclusion: Codable, Equatable {
        public var decisionID: String
        public var reason: String
        public var mustardVisibility: String
        enum CodingKeys: String, CodingKey {
            case decisionID = "decision_id", reason, mustardVisibility = "mustard_visibility"
        }
    }

    public struct Cluster: Codable, Equatable {
        public var clusterID: String
        public var projectID: String
        public var title: String
        public var triageState: String
        public var mustardStage: String
        public var priority: String
        public var decisionRequired: Bool
        public var humanActionRequired: Bool
        public var question: String
        public var nextAction: String
        public var whyGrouped: String
        public var sourceDecisionIDs: [String]

        public init(clusterID: String, projectID: String, title: String, triageState: String, mustardStage: String, priority: String, decisionRequired: Bool, humanActionRequired: Bool, question: String, nextAction: String, whyGrouped: String, sourceDecisionIDs: [String]) {
            self.clusterID = clusterID; self.projectID = projectID; self.title = title; self.triageState = triageState
            self.mustardStage = mustardStage; self.priority = priority; self.decisionRequired = decisionRequired
            self.humanActionRequired = humanActionRequired; self.question = question; self.nextAction = nextAction
            self.whyGrouped = whyGrouped; self.sourceDecisionIDs = sourceDecisionIDs
        }

        enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id", projectID = "project_id", title
            case triageState = "triage_state", mustardStage = "mustard_stage", priority
            case decisionRequired = "decision_required", humanActionRequired = "human_action_required"
            case question, nextAction = "next_action", whyGrouped = "why_grouped"
            case sourceDecisionIDs = "source_decision_ids"
        }
    }

    public enum JSONValue: Codable, Equatable {
        case string(String), int(Int), bool(Bool), double(Double), null
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Int.self) { self = .int(value) }
            else if let value = try? c.decode(Double.self) { self = .double(value) }
            else { self = .string(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let v): try c.encode(v); case .int(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .double(let v): try c.encode(v); case .null: try c.encodeNil() }
        }
        fileprivate var text: String { switch self { case .string(let v): v; case .int(let v): String(v); case .bool(let v): String(v); case .double(let v): String(v); case .null: "" } }
    }

    public enum FindingScope: String, Equatable { case queue, cluster }
    public struct Finding: Equatable {
        public let scope: FindingScope
        public let clusterID: String?
        public let reason: String
        public init(scope: FindingScope, clusterID: String? = nil, reason: String) { self.scope = scope; self.clusterID = clusterID; self.reason = reason }
    }
    public enum ValidationError: Error, Equatable { case queue(Finding) }
    public struct ClusterValidationResult: Equatable { public let eligible: [Cluster]; public let findings: [Finding] }

    /// A normalized, identifier-only source reference. Path-bearing values are rejected
    /// at this contract boundary; a future adapter supplies the safe resolved location.
    public struct SourceReference: Equatable, Hashable {
        public let decisionID: String
        public init(_ rawValue: String) throws {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.range(of: #"^DEC-[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw SourceReferenceError.invalid(rawValue) }
            self.decisionID = normalized
        }
    }
    public enum SourceReferenceError: Error, Equatable { case invalid(String) }

    public static func validate(_ document: Document) throws {
        guard document.schemaVersion == 1 else { throw ValidationError.queue(.init(scope: .queue, reason: "Unsupported schema version")) }
        guard document.reportType == "dream_decision_triage" else { throw ValidationError.queue(.init(scope: .queue, reason: "Unsupported report type")) }
        guard generatedAtDate(document.generatedAt) != nil else { throw ValidationError.queue(.init(scope: .queue, reason: "Invalid generated_at timestamp")) }
        guard document.readOnly else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue is not read-only")) }
        guard document.decisionStatusMutations == 0 else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue reports decision mutations")) }
        guard isReadOnlyImportMarker(document.mustardImport) else { throw ValidationError.queue(.init(scope: .queue, reason: "Unsupported Mustard import mode")) }
        guard document.sourceRunID.range(of: #"^RUN-[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw ValidationError.queue(.init(scope: .queue, reason: "Missing RUN source ID")) }
        guard !document.sourceReceipt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.queue(.init(scope: .queue, reason: "Missing source receipt")) }
        guard !document.queue.isEmpty else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue is empty")) }
        let ids = document.queue.map(\.clusterID)
        guard Set(ids).count == ids.count else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue has duplicate cluster IDs")) }
        guard ids.allSatisfy({ $0.range(of: clusterIDPattern, options: .regularExpression) != nil }) else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue has invalid cluster IDs")) }
        guard !containsSecret(in: queueLevelText(document)) else { throw ValidationError.queue(.init(scope: .queue, reason: "Queue-level secret-shaped content")) }
    }

    /// Parses the queue provenance timestamp used to order local projections.
    public static func generatedAtDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    public static func clusterValidation(for document: Document) -> ClusterValidationResult {
        var eligible: [Cluster] = []; var findings: [Finding] = []; var seenSources = Set<SourceReference>()
        for cluster in document.queue {
            let invalid: String?
            if containsSecret(in: clusterText(cluster)) { invalid = "Source-level secret-shaped content" }
            else if (try? CodeHeroesDecisionPolicy.area(for: cluster.projectID)) == nil { invalid = "Unknown project" }
            else if (try? CodeHeroesDecisionPolicy.stage(for: cluster.mustardStage)) == nil { invalid = "Invalid stage" }
            else if (try? CodeHeroesDecisionPolicy.priority(for: cluster.priority)) == nil { invalid = "Invalid priority" }
            else if cluster.sourceDecisionIDs.isEmpty || cluster.sourceDecisionIDs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { invalid = "Missing decision source" }
            else {
                let references = cluster.sourceDecisionIDs.compactMap { try? SourceReference($0) }
                if references.count != cluster.sourceDecisionIDs.count { invalid = "Missing or escaped decision source" }
                else if Set(references).count != references.count || references.contains(where: { seenSources.contains($0) }) { invalid = "Duplicate source identity" }
                else { invalid = nil; seenSources.formUnion(references) }
            }
            if let invalid { findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: invalid)) } else { eligible.append(cluster) }
        }
        return .init(eligible: eligible, findings: findings)
    }

    private static func isReadOnlyImportMarker(_ marker: String) -> Bool { approvedReadOnlyImportMarkers.contains(marker) }
    private static func queueLevelText(_ document: Document) -> String {
        let exclusions = document.historicalExclusions.flatMap { [$0.decisionID, $0.reason, $0.mustardVisibility] }
        return ([document.generatedAt, document.sourceRunID, document.sourceReceipt, document.canonicalInput, document.mustardImport]
            + document.historicalOpenDecisionIDs + exclusions + document.summary.values.map(\.text)).joined(separator: "\n")
    }
    private static func clusterText(_ cluster: Cluster) -> String { ([cluster.title, cluster.question, cluster.nextAction, cluster.whyGrouped] + cluster.sourceDecisionIDs).joined(separator: "\n") }
    private static func containsSecret(in value: String) -> Bool { value.range(of: #"(?i)(ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|sk-proj-[a-z0-9_-]{16,}|sk-[a-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"#, options: .regularExpression) != nil }
}
