import Foundation

/// Pure mapping and read-only projection policy for Code Heroes decision clusters.
public enum CodeHeroesDecisionPolicy {
    public static let source = "codeheroes:decision-triage"

    public enum PolicyError: Error, Equatable { case unknownProject(String), invalidStage(String), invalidPriority(String) }
    public struct Projection: Equatable {
        public let uid: String; public let title: String; public let area: String; public let stage: TaskStage
        public let priority: TaskPriority; public let owner: TaskOwner; public let tags: [String]; public let notes: String
        public let source: String; public let sourceDecisionIDs: [String]; public let isReadOnly: Bool
    }

    public static func area(for projectID: String) throws -> String {
        switch projectID { case "dl": "Digital Licence"; case "sales-buddi": "Sales Buddi"; case "sandvik": "Sandvik"; case "code-heroes-internal", "cross-project": "Code Heroes"; default: throw PolicyError.unknownProject(projectID) }
    }
    public static func stage(for rawValue: String) throws -> TaskStage {
        switch rawValue { case "needsInput": .needsInput; case "needsReview": .needsReview; default: throw PolicyError.invalidStage(rawValue) }
    }
    public static func priority(for rawValue: String) throws -> TaskPriority {
        switch rawValue { case "high": .high; case "medium": .normal; case "low": .low; case "urgent": .urgent; default: throw PolicyError.invalidPriority(rawValue) }
    }
    public static func uid(clusterID: String) -> String { "codeheroes:decision:\(clusterID)" }
    public static func isProjection(source: String) -> Bool { source == self.source }
    public static func isProjection(_ projection: Projection) -> Bool { projection.isReadOnly && isProjection(source: projection.source) }
    public static func isProjection(_ task: MustardTask) -> Bool { isProjection(source: task.source) }

    public static func projection(for cluster: CodeHeroesDecisionQueue.Cluster) throws -> Projection {
        var tags = ["codeheroes", "decision", "project:\(cluster.projectID)", "triage:\(cluster.triageState)"]
        if cluster.humanActionRequired { tags.append("human-action") }
        return .init(uid: uid(clusterID: cluster.clusterID), title: cluster.title, area: try area(for: cluster.projectID), stage: try stage(for: cluster.mustardStage), priority: try priority(for: cluster.priority), owner: .agent, tags: tags, notes: boundedNotes(for: cluster), source: source, sourceDecisionIDs: cluster.sourceDecisionIDs, isReadOnly: true)
    }

    public static func boundedNotes(for cluster: CodeHeroesDecisionQueue.Cluster) -> String {
        let text = "Question: \(bounded(cluster.question))\nNext action: \(bounded(cluster.nextAction))\nWhy grouped: \(bounded(cluster.whyGrouped))\nSource IDs: \(cluster.sourceDecisionIDs.joined(separator: ", "))"
        return String(text.prefix(1_200))
    }
    private static func bounded(_ text: String) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280)) }
}
