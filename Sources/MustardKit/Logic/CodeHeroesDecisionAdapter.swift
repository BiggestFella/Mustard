import CryptoKit
import Foundation
import SwiftData

/// Injectable, read-only filesystem boundary used by the decision importer.
/// The adapter invokes every closure from its detached snapshot task, never from
/// the MainActor where SwiftData reconciliation occurs.
struct CodeHeroesDecisionFileAccess: @unchecked Sendable {
    private final class FileManagerBox: @unchecked Sendable {
        let value: FileManager
        init(_ value: FileManager) { self.value = value }
    }

    struct Metadata: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case regularFile, directory, other }
        let kind: Kind
        let size: Int?
    }

    let normalize: @Sendable (URL) -> URL
    let metadata: @Sendable (URL) -> Metadata?
    let contents: @Sendable (URL) -> Data?

    init(
        fileManager: FileManager = .default,
        normalize: (@Sendable (URL) -> URL)? = nil,
        metadata: (@Sendable (URL) -> Metadata?)? = nil,
        contents: (@Sendable (URL) -> Data?)? = nil
    ) {
        let fileManager = FileManagerBox(fileManager)
        self.normalize = normalize ?? { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.metadata = metadata ?? { url in
            guard let attributes = try? fileManager.value.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else { return nil }
            let kind: Metadata.Kind
            switch type {
            case .typeRegular: kind = .regularFile
            case .typeDirectory: kind = .directory
            default: kind = .other
            }
            return Metadata(kind: kind, size: (attributes[.size] as? NSNumber)?.intValue)
        }
        self.contents = contents ?? { fileManager.value.contents(atPath: $0.path) }
    }
}

/// Read-only importer for the reviewed Code Heroes decision queue. It reads only
/// files beneath its injected repository root and writes projection tasks locally.
@MainActor
public final class CodeHeroesDecisionAdapter {
    public struct ImportReport: Equatable {
        public let queuePath: String
        public let queueDigest: String?
        public let sourceRunID: String?
        public let startedAt: Date
        public let endedAt: Date
        public let createdCount: Int
        public let updatedCount: Int
        public let unchangedCount: Int
        public let staleCount: Int
        public let skippedCount: Int
        public let collisionCount: Int
        public let findings: [CodeHeroesDecisionQueue.Finding]
        public let readOnly: Bool
        public let repositoryWrites: Int
        public let externalWrites: Int
        public var summary: String {
            "Code Heroes decision import: \(createdCount) created, \(updatedCount) updated, \(unchangedCount) unchanged, \(staleCount) stale, \(skippedCount) skipped, \(collisionCount) collisions."
        }
    }

    private let context: ModelContext
    private let repositoryRoot: URL
    private let fileAccess: CodeHeroesDecisionFileAccess
    private let now: () -> Date
    private let saveContext: () throws -> Void
    private nonisolated static let maximumQueueBytes = 5 * 1_024 * 1_024
    private nonisolated static let maximumDecisionSourceBytes = 2 * 1_024 * 1_024

    public init(context: ModelContext, repositoryRoot: URL, fileManager: FileManager = .default, now: @escaping () -> Date = { .now }, saveContext: (() throws -> Void)? = nil) {
        self.context = context
        self.repositoryRoot = repositoryRoot
        self.fileAccess = CodeHeroesDecisionFileAccess(fileManager: fileManager)
        self.now = now
        self.saveContext = saveContext ?? { try context.save() }
    }

    init(context: ModelContext, repositoryRoot: URL, fileAccess: CodeHeroesDecisionFileAccess, now: @escaping () -> Date = { .now }, saveContext: (() throws -> Void)? = nil) {
        self.context = context
        self.repositoryRoot = repositoryRoot
        self.fileAccess = fileAccess
        self.now = now
        self.saveContext = saveContext ?? { try context.save() }
    }

    public func importQueue(at queueURL: URL) async -> ImportReport {
        let startedAt = now()
        let repositoryRoot = self.repositoryRoot
        let fileAccess = self.fileAccess
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.loadSnapshot(queueURL: queueURL, repositoryRoot: repositoryRoot, fileAccess: fileAccess)
        }.value
        let queuePath = snapshot.queuePath
        func report(_ digest: String? = nil, _ runID: String? = nil, _ findings: [CodeHeroesDecisionQueue.Finding], created: Int = 0, updated: Int = 0, unchanged: Int = 0, stale: Int = 0, skipped: Int = 0, collisions: Int = 0) -> ImportReport {
            .init(queuePath: queuePath, queueDigest: digest, sourceRunID: runID, startedAt: startedAt, endedAt: now(), createdCount: created, updatedCount: updated, unchangedCount: unchanged, staleCount: stale, skippedCount: skipped, collisionCount: collisions, findings: findings, readOnly: true, repositoryWrites: 0, externalWrites: 0)
        }

        guard case .ready(let prepared) = snapshot else {
            return report(snapshot.digest, snapshot.runID, snapshot.findings)
        }
        let normalizedQueue = prepared.queueURL
        let digest = prepared.digest
        let receiptURL = prepared.receiptURL
        var findings = prepared.findings
        let skipped = prepared.skipped

        let allTasks = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        let tasksByUID = Dictionary(grouping: allTasks, by: \.uid)
        let snapshots = allTasks.filter { $0.source == CodeHeroesDecisionPolicy.source }.map { ($0, TaskSnapshot(task: $0)) }
        var insertedTasks: [MustardTask] = [], insertedAreas: [Area] = [], insertedLists: [TaskList] = []
        var created = 0, updated = 0, unchanged = 0, collisions = 0, stale = 0
        var changed = false

        for preparedCluster in prepared.clusters {
            let projection = preparedCluster.projection
            let existingTasks = tasksByUID[projection.uid] ?? []
            guard existingTasks.count <= 1 else {
                findings.append(.init(scope: .cluster, clusterID: preparedCluster.clusterID, reason: "Projection UID collides with multiple existing tasks")); collisions += 1; continue
            }
            if let existing = existingTasks.first, existing.source != CodeHeroesDecisionPolicy.source {
                findings.append(.init(scope: .cluster, clusterID: preparedCluster.clusterID, reason: "Projection UID collides with a non-Code-Heroes task")); collisions += 1; continue
            }
            let links = stableLinks(queueURL: normalizedQueue, receiptURL: receiptURL, decisionURLs: preparedCluster.sourceURLs)
            let metadata = sourceContext(digest: digest, runID: prepared.runID, generatedAt: prepared.generatedAt, clusterID: preparedCluster.clusterID, sourceIDs: projection.sourceDecisionIDs)
            let projectionList = list(for: projection.area, insertedAreas: &insertedAreas, insertedLists: &insertedLists)
            if let task = existingTasks.first {
                if matches(projection: projection, task: task, list: projectionList, sourceURL: normalizedQueue.path, sourceContext: metadata, links: links) { unchanged += 1; continue }
                apply(projection: projection, to: task, list: projectionList, sourceURL: normalizedQueue.path, sourceContext: metadata, links: links)
                updated += 1; changed = true
            } else {
                let task = MustardTask(title: projection.title, owner: .agent)
                task.createdAt = startedAt
                apply(projection: projection, to: task, list: projectionList, sourceURL: normalizedQueue.path, sourceContext: metadata, links: links)
                context.insert(task); insertedTasks.append(task)
                created += 1; changed = true
            }
        }

        for task in allTasks where task.source == CodeHeroesDecisionPolicy.source {
            guard task.sourceURL == normalizedQueue.path,
                  let clusterID = contextValue("cluster", in: task.sourceContext),
                  !prepared.incomingIDs.contains(clusterID),
                  !task.tags.contains("source-stale"),
                  let priorGeneratedAt = contextValue("generated_at", in: task.sourceContext).flatMap(CodeHeroesDecisionQueue.generatedAtDate),
                  prepared.incomingGeneratedAt >= priorGeneratedAt else { continue }
            task.tags = Array(Set(task.tags + ["source-stale"])).sorted()
            task.stage = .needsReview
            task.notes = String((task.notes + "\nSource health: absent from latest read-only queue; review before acting.").prefix(1_200))
            stale += 1; changed = true
        }
        if changed {
            do { try saveContext() }
            catch {
                for (task, snapshot) in snapshots { snapshot.restore(on: task) }
                for task in insertedTasks { context.delete(task) }
                for list in insertedLists { context.delete(list) }
                for area in insertedAreas { context.delete(area) }
                findings.append(queueFinding("Local projection save failed"))
                return report(digest, prepared.runID, findings, skipped: skipped, collisions: collisions)
            }
        }
        return report(digest, prepared.runID, findings, created: created, updated: updated, unchanged: unchanged, stale: stale, skipped: skipped, collisions: collisions)
    }

    private struct PreparedCluster: @unchecked Sendable {
        let clusterID: String
        let projection: CodeHeroesDecisionPolicy.Projection
        let sourceURLs: [URL]
    }

    private struct PreparedSnapshot: @unchecked Sendable {
        let queueURL: URL
        let digest: String
        let runID: String
        let generatedAt: String
        let incomingGeneratedAt: Date
        let incomingIDs: Set<String>
        let receiptURL: URL
        let clusters: [PreparedCluster]
        let findings: [CodeHeroesDecisionQueue.Finding]
        let skipped: Int
    }

    private enum Snapshot: @unchecked Sendable {
        case rejected(
            queuePath: String,
            digest: String?,
            runID: String?,
            findings: [CodeHeroesDecisionQueue.Finding]
        )
        case ready(PreparedSnapshot)

        var queuePath: String {
            switch self {
            case .rejected(let queuePath, _, _, _): queuePath
            case .ready(let prepared): prepared.queueURL.path
            }
        }
        var digest: String? {
            switch self {
            case .rejected(_, let digest, _, _): digest
            case .ready(let prepared): prepared.digest
            }
        }
        var runID: String? {
            switch self {
            case .rejected(_, _, let runID, _): runID
            case .ready(let prepared): prepared.runID
            }
        }
        var findings: [CodeHeroesDecisionQueue.Finding] {
            switch self {
            case .rejected(_, _, _, let findings): findings
            case .ready(let prepared): prepared.findings
            }
        }
    }

    /// Performs every potentially blocking filesystem operation and every validation
    /// read before any SwiftData object is touched on MainActor.
    private nonisolated static func loadSnapshot(
        queueURL: URL,
        repositoryRoot: URL,
        fileAccess: CodeHeroesDecisionFileAccess
    ) -> Snapshot {
        let normalizedRoot = fileAccess.normalize(repositoryRoot)
        let normalizedQueue = fileAccess.normalize(queueURL)
        let queuePath = normalizedQueue.path
        func rejected(
            _ reason: String,
            digest: String? = nil,
            runID: String? = nil
        ) -> Snapshot {
            .rejected(
                queuePath: queuePath,
                digest: digest,
                runID: runID,
                findings: [.init(scope: .queue, reason: reason)]
            )
        }

        guard isWithin(normalizedQueue, root: normalizedRoot),
              let queueMetadata = fileAccess.metadata(normalizedQueue),
              queueMetadata.kind == .regularFile else {
            return rejected("Queue path is not a regular file beneath the configured repository root")
        }
        guard (queueMetadata.size ?? Int.max) <= maximumQueueBytes else {
            return rejected("Queue file exceeds the safe size limit")
        }
        guard let data = fileAccess.contents(normalizedQueue) else {
            return rejected("Unable to read queue file")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let document: CodeHeroesDecisionQueue.Document
        do { document = try JSONDecoder().decode(CodeHeroesDecisionQueue.Document.self, from: data) }
        catch { return rejected("Queue JSON could not be decoded", digest: digest) }
        do { try CodeHeroesDecisionQueue.validate(document) }
        catch let CodeHeroesDecisionQueue.ValidationError.queue(finding) {
            return .rejected(queuePath: queuePath, digest: digest, runID: document.sourceRunID, findings: [finding])
        }
        catch { return rejected("Queue validation failed", digest: digest, runID: document.sourceRunID) }
        guard let incomingGeneratedAt = CodeHeroesDecisionQueue.generatedAtDate(document.generatedAt) else {
            return rejected("Invalid generated_at timestamp", digest: digest, runID: document.sourceRunID)
        }

        guard let receiptURL = resolvedRelative(
            document.sourceReceipt,
            repositoryRoot: normalizedRoot,
            fileAccess: fileAccess
        ), fileAccess.metadata(receiptURL)?.kind == .regularFile else {
            return rejected(
                "Source receipt is not a regular file beneath the configured repository root",
                digest: digest,
                runID: document.sourceRunID
            )
        }

        let clusterValidation = CodeHeroesDecisionQueue.clusterValidation(for: document)
        var findings = clusterValidation.findings
        var eligible = clusterValidation.eligible
        var skipped = findings.count
        var sourceURLs: [String: [URL]] = [:]
        for cluster in eligible {
            let paths = decisionURLs(
                for: cluster.sourceDecisionIDs,
                repositoryRoot: normalizedRoot,
                fileAccess: fileAccess
            )
            let sourceIssue = paths.count != cluster.sourceDecisionIDs.count
                ? "Missing or escaped decision source"
                : sourceValidationIssue(for: paths, fileAccess: fileAccess)
            if let sourceIssue {
                findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: sourceIssue))
                skipped += 1
                sourceURLs[cluster.clusterID] = []
            } else {
                sourceURLs[cluster.clusterID] = paths
            }
        }
        eligible.removeAll { (sourceURLs[$0.clusterID] ?? []).isEmpty }

        var preparedClusters: [PreparedCluster] = []
        for cluster in eligible {
            do {
                preparedClusters.append(.init(
                    clusterID: cluster.clusterID,
                    projection: try CodeHeroesDecisionPolicy.projection(for: cluster),
                    sourceURLs: sourceURLs[cluster.clusterID] ?? []
                ))
            } catch {
                findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: "Projection mapping failed"))
                skipped += 1
            }
        }

        return .ready(.init(
            queueURL: normalizedQueue,
            digest: digest,
            runID: document.sourceRunID,
            generatedAt: document.generatedAt,
            incomingGeneratedAt: incomingGeneratedAt,
            incomingIDs: Set(document.queue.map(\.clusterID)),
            receiptURL: receiptURL,
            clusters: preparedClusters,
            findings: findings,
            skipped: skipped
        ))
    }

    private nonisolated static func resolvedRelative(
        _ value: String,
        repositoryRoot: URL,
        fileAccess: CodeHeroesDecisionFileAccess
    ) -> URL? {
        guard !value.isEmpty, !value.hasPrefix("/") else { return nil }
        let resolved = fileAccess.normalize(repositoryRoot.appendingPathComponent(value))
        return isWithin(resolved, root: repositoryRoot) ? resolved : nil
    }

    private nonisolated static func decisionURLs(
        for ids: [String],
        repositoryRoot: URL,
        fileAccess: CodeHeroesDecisionFileAccess
    ) -> [URL] {
        ids.compactMap { id in
            guard (try? CodeHeroesDecisionQueue.SourceReference(id)) != nil else { return nil }
            for directory in ["operations/decisions/open", "operations/decisions/resolved"] {
                let realDirectory = fileAccess.normalize(
                    repositoryRoot.appendingPathComponent(directory, isDirectory: true)
                )
                guard isWithin(realDirectory, root: repositoryRoot),
                      fileAccess.metadata(realDirectory)?.kind == .directory else { continue }
                let candidate = fileAccess.normalize(realDirectory.appendingPathComponent("\(id).md"))
                if isWithin(candidate, root: repositoryRoot),
                   fileAccess.metadata(candidate)?.kind == .regularFile { return candidate }
            }
            return nil
        }
    }

    private nonisolated static func sourceValidationIssue(
        for urls: [URL],
        fileAccess: CodeHeroesDecisionFileAccess
    ) -> String? {
        for url in urls {
            guard (fileAccess.metadata(url)?.size ?? Int.max) <= maximumDecisionSourceBytes else {
                return "Source decision exceeds the safe size limit"
            }
            guard let data = fileAccess.contents(url),
                  let text = String(data: data, encoding: .utf8) else {
                return "Unable to read decision source"
            }
            if text.range(
                of: #"(?i)(ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|sk-proj-[a-z0-9_-]{16,}|sk-[a-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"#,
                options: .regularExpression
            ) != nil { return "Source-level secret-shaped content" }
        }
        return nil
    }

    private nonisolated static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    private func apply(projection: CodeHeroesDecisionPolicy.Projection, to task: MustardTask, list: TaskList, sourceURL: String, sourceContext: String, links: [TaskLink]) {
        task.uid = projection.uid; task.title = projection.title; task.notes = projection.notes; task.list = list
        task.stage = projection.stage; task.priority = projection.priority; task.owner = projection.owner; task.tags = projection.tags
        task.source = projection.source; task.sourceURL = sourceURL; task.sourceContext = sourceContext; task.links = links
        task.actionTypeRaw = nil; task.confidence = nil; task.delegation = nil; task.agentRun = nil
    }

    private func list(for areaName: String, insertedAreas: inout [Area], insertedLists: inout [TaskList]) -> TaskList {
        let areas = (try? context.fetch(FetchDescriptor<Area>())) ?? []
        if let area = areas.first(where: { $0.name == areaName }) {
            if let list = (area.lists ?? []).first(where: { $0.name == areaName }) ?? area.lists?.first { return list }
            let list = TaskList(name: areaName, area: area); context.insert(list); insertedLists.append(list); return list
        }
        let area = Area(name: areaName); context.insert(area); insertedAreas.append(area)
        let list = TaskList(name: areaName, area: area); context.insert(list); insertedLists.append(list); return list
    }

    private func stableLinks(queueURL: URL, receiptURL: URL, decisionURLs: [URL]) -> [TaskLink] {
        [TaskLink(label: "Queue", url: queueURL.path), TaskLink(label: "Run", url: receiptURL.path)] + decisionURLs.sorted { $0.path < $1.path }.map { TaskLink(label: "Decision", url: $0.path) }
    }
    private func matches(projection: CodeHeroesDecisionPolicy.Projection, task: MustardTask, list: TaskList, sourceURL: String, sourceContext: String, links: [TaskLink]) -> Bool {
        task.uid == projection.uid && task.title == projection.title && task.notes == projection.notes && task.list === list
            && task.stage == projection.stage && task.priority == projection.priority && task.owner == projection.owner
            && task.tags == projection.tags && task.source == projection.source && task.sourceURL == sourceURL
            && task.sourceContext == sourceContext && task.links == links && task.actionTypeRaw == nil
            && task.confidence == nil && task.delegation == nil && task.agentRun == nil
    }
    private func sourceContext(digest: String, runID: String, generatedAt: String, clusterID: String, sourceIDs: [String]) -> String { String("digest=\(digest);run=\(runID);generated_at=\(generatedAt);cluster=\(clusterID);source_ids=\(sourceIDs.sorted().joined(separator: ","))".prefix(900)) }
    private func contextValue(_ key: String, in context: String) -> String? { context.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) } }
    private func queueFinding(_ reason: String) -> CodeHeroesDecisionQueue.Finding { .init(scope: .queue, reason: reason) }

    private struct TaskSnapshot {
        let uid: String; let title: String; let notes: String; let list: TaskList?; let stageRaw: String
        let priorityRaw: String; let ownerRaw: String; let tags: [String]; let source: String; let sourceURL: String?
        let sourceContext: String; let links: [TaskLink]; let actionTypeRaw: String?; let confidence: Double?
        let delegation: Recommendation?; let agentRun: AgentRun?
        init(task: MustardTask) {
            uid = task.uid; title = task.title; notes = task.notes; list = task.list; stageRaw = task.stageRaw
            priorityRaw = task.priorityRaw; ownerRaw = task.ownerRaw; tags = task.tags; source = task.source
            sourceURL = task.sourceURL; sourceContext = task.sourceContext; links = task.links; actionTypeRaw = task.actionTypeRaw
            confidence = task.confidence; delegation = task.delegation; agentRun = task.agentRun
        }
        func restore(on task: MustardTask) {
            task.uid = uid; task.title = title; task.notes = notes; task.list = list; task.stageRaw = stageRaw
            task.priorityRaw = priorityRaw; task.ownerRaw = ownerRaw; task.tags = tags; task.source = source
            task.sourceURL = sourceURL; task.sourceContext = sourceContext; task.links = links; task.actionTypeRaw = actionTypeRaw
            task.confidence = confidence; task.delegation = delegation; task.agentRun = agentRun
        }
    }
}
