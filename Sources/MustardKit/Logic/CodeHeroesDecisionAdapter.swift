import CryptoKit
import Foundation
import SwiftData

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
    private let fileManager: FileManager
    private let now: () -> Date

    public init(context: ModelContext, repositoryRoot: URL, fileManager: FileManager = .default, now: @escaping () -> Date = { .now }) {
        self.context = context
        self.repositoryRoot = Self.normalized(repositoryRoot)
        self.fileManager = fileManager
        self.now = now
    }

    public func importQueue(at queueURL: URL) -> ImportReport {
        let startedAt = now()
        let queuePath = Self.normalized(queueURL).path
        func report(_ digest: String? = nil, _ runID: String? = nil, _ findings: [CodeHeroesDecisionQueue.Finding], created: Int = 0, updated: Int = 0, unchanged: Int = 0, stale: Int = 0, skipped: Int = 0, collisions: Int = 0) -> ImportReport {
            .init(queuePath: queuePath, queueDigest: digest, sourceRunID: runID, startedAt: startedAt, endedAt: now(), createdCount: created, updatedCount: updated, unchangedCount: unchanged, staleCount: stale, skippedCount: skipped, collisionCount: collisions, findings: findings, readOnly: true, repositoryWrites: 0, externalWrites: 0)
        }

        let normalizedQueue = Self.normalized(queueURL)
        guard isRegularFile(normalizedQueue), isWithinRoot(normalizedQueue) else {
            return report(nil, nil, [queueFinding("Queue path is not a regular file beneath the configured repository root")])
        }
        guard let data = fileManager.contents(atPath: normalizedQueue.path) else {
            return report(nil, nil, [queueFinding("Unable to read queue file")])
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let document: CodeHeroesDecisionQueue.Document
        do { document = try JSONDecoder().decode(CodeHeroesDecisionQueue.Document.self, from: data) }
        catch { return report(digest, nil, [queueFinding("Queue JSON could not be decoded")]) }
        do { try CodeHeroesDecisionQueue.validate(document) }
        catch let CodeHeroesDecisionQueue.ValidationError.queue(finding) { return report(digest, document.sourceRunID, [finding]) }
        catch { return report(digest, document.sourceRunID, [queueFinding("Queue validation failed")]) }

        guard let receiptURL = resolvedRelative(document.sourceReceipt), isRegularFile(receiptURL) else {
            return report(digest, document.sourceRunID, [queueFinding("Source receipt is not a regular file beneath the configured repository root")])
        }

        var findings = CodeHeroesDecisionQueue.clusterValidation(for: document).findings
        var eligible = CodeHeroesDecisionQueue.clusterValidation(for: document).eligible
        var skipped = findings.count
        var sourceURLs: [String: [URL]] = [:]
        for cluster in eligible {
            let paths = decisionURLs(for: cluster.sourceDecisionIDs)
            if paths.count != cluster.sourceDecisionIDs.count || paths.contains(where: { sourceContainsSecret($0) }) {
                findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: paths.count != cluster.sourceDecisionIDs.count ? "Missing or escaped decision source" : "Source-level secret-shaped content"))
                skipped += 1
                sourceURLs[cluster.clusterID] = []
            } else { sourceURLs[cluster.clusterID] = paths }
        }
        eligible.removeAll { (sourceURLs[$0.clusterID] ?? []).isEmpty }

        let allTasks = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        var tasksByUID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.uid, $0) })
        var created = 0, updated = 0, unchanged = 0, collisions = 0, stale = 0
        var changed = false
        let incomingIDs = Set(eligible.map(\.clusterID))

        for cluster in eligible {
            let projection: CodeHeroesDecisionPolicy.Projection
            do { projection = try CodeHeroesDecisionPolicy.projection(for: cluster) }
            catch { findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: "Projection mapping failed")); skipped += 1; continue }
            if let existing = tasksByUID[projection.uid], existing.source != CodeHeroesDecisionPolicy.source {
                findings.append(.init(scope: .cluster, clusterID: cluster.clusterID, reason: "Projection UID collides with a non-Code-Heroes task")); collisions += 1; continue
            }
            let links = stableLinks(queueURL: normalizedQueue, receiptURL: receiptURL, decisionURLs: sourceURLs[cluster.clusterID] ?? [])
            let metadata = sourceContext(digest: digest, runID: document.sourceRunID, clusterID: cluster.clusterID, sourceIDs: projection.sourceDecisionIDs)
            if let task = tasksByUID[projection.uid] {
                if task.sourceContext == metadata { unchanged += 1; continue }
                apply(projection: projection, to: task, list: list(for: projection.area), sourceURL: normalizedQueue.path, sourceContext: metadata, links: links)
                updated += 1; changed = true
            } else {
                let task = MustardTask(title: projection.title, owner: .agent)
                task.createdAt = startedAt
                apply(projection: projection, to: task, list: list(for: projection.area), sourceURL: normalizedQueue.path, sourceContext: metadata, links: links)
                context.insert(task); tasksByUID[projection.uid] = task
                created += 1; changed = true
            }
        }

        for task in allTasks where task.source == CodeHeroesDecisionPolicy.source {
            guard let clusterID = contextValue("cluster", in: task.sourceContext), !incomingIDs.contains(clusterID), !task.tags.contains("source-stale") else { continue }
            task.tags = Array(Set(task.tags + ["source-stale"])).sorted()
            task.stage = .needsReview
            task.notes = String((task.notes + "\nSource health: absent from latest read-only queue; review before acting.").prefix(1_200))
            stale += 1; changed = true
        }
        if changed { do { try context.save() } catch { findings.append(queueFinding("Local projection save failed")) } }
        return report(digest, document.sourceRunID, findings, created: created, updated: updated, unchanged: unchanged, stale: stale, skipped: skipped, collisions: collisions)
    }

    private func apply(projection: CodeHeroesDecisionPolicy.Projection, to task: MustardTask, list: TaskList, sourceURL: String, sourceContext: String, links: [TaskLink]) {
        task.uid = projection.uid; task.title = projection.title; task.notes = projection.notes; task.list = list
        task.stage = projection.stage; task.priority = projection.priority; task.owner = projection.owner; task.tags = projection.tags
        task.source = projection.source; task.sourceURL = sourceURL; task.sourceContext = sourceContext; task.links = links
        task.actionTypeRaw = nil; task.confidence = nil; task.delegation = nil; task.agentRun = nil
    }

    private func list(for areaName: String) -> TaskList {
        let areas = (try? context.fetch(FetchDescriptor<Area>())) ?? []
        if let area = areas.first(where: { $0.name == areaName }) {
            if let list = (area.lists ?? []).first(where: { $0.name == areaName }) ?? area.lists?.first { return list }
            let list = TaskList(name: areaName, area: area); context.insert(list); return list
        }
        let area = Area(name: areaName); context.insert(area)
        let list = TaskList(name: areaName, area: area); context.insert(list); return list
    }

    private func decisionURLs(for ids: [String]) -> [URL] {
        ids.compactMap { id in
            guard (try? CodeHeroesDecisionQueue.SourceReference(id)) != nil else { return nil }
            for directory in ["operations/decisions/open", "operations/decisions/resolved"] {
                let realDirectory = Self.normalized(repositoryRoot.appendingPathComponent(directory, isDirectory: true))
                guard isWithinRoot(realDirectory), isDirectory(realDirectory) else { continue }
                let candidate = Self.normalized(realDirectory.appendingPathComponent("\(id).md"))
                if isWithinRoot(candidate), isRegularFile(candidate) { return candidate }
            }
            return nil
        }
    }

    private func stableLinks(queueURL: URL, receiptURL: URL, decisionURLs: [URL]) -> [TaskLink] {
        [TaskLink(label: "Queue", url: queueURL.path), TaskLink(label: "Run", url: receiptURL.path)] + decisionURLs.sorted { $0.path < $1.path }.map { TaskLink(label: "Decision", url: $0.path) }
    }
    private func sourceContext(digest: String, runID: String, clusterID: String, sourceIDs: [String]) -> String { String("digest=\(digest);run=\(runID);cluster=\(clusterID);source_ids=\(sourceIDs.sorted().joined(separator: ","))".prefix(900)) }
    private func contextValue(_ key: String, in context: String) -> String? { context.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) } }
    private func resolvedRelative(_ value: String) -> URL? {
        guard !value.isEmpty, !value.hasPrefix("/") else { return nil }
        let resolved = Self.normalized(repositoryRoot.appendingPathComponent(value))
        return isWithinRoot(resolved) ? resolved : nil
    }
    private func isWithinRoot(_ url: URL) -> Bool { let path = Self.normalized(url).path; return path == repositoryRoot.path || path.hasPrefix(repositoryRoot.path + "/") }
    private func isRegularFile(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }
    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private func sourceContainsSecret(_ url: URL) -> Bool {
        guard let data = fileManager.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else { return true }
        return text.range(of: #"(?i)(ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|sk-proj-[a-z0-9_-]{16,}|sk-[a-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"#, options: .regularExpression) != nil
    }
    private func queueFinding(_ reason: String) -> CodeHeroesDecisionQueue.Finding { .init(scope: .queue, reason: reason) }
    private static func normalized(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}
