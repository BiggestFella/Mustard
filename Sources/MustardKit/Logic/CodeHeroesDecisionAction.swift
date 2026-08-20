import CryptoKit
import Foundation

/// The bounded actions Mustard can request from the Code Heroes adapter.
public enum CodeHeroesDecisionActionKind: String, Codable, CaseIterable, Sendable {
    case approveAndRun = "approve-and-run"
    case ignore
    case comment
}

/// JSON-compatible request envelope written to the Code Heroes adapter boundary.
/// The adapter remains the only writer of Code Heroes decision records.
public struct CodeHeroesDecisionActionRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let action: CodeHeroesDecisionActionKind
    public let actor: String
    public let clusterID: String
    public let decisionIDs: [String]
    public let queueDigest: String
    public let decisionDigests: [String: String]
    public let selectedOptions: [String: String]
    public let comment: String?
    public let requestedAt: String
    public let mustardRunID: String?

    public init(
        requestID: String,
        action: CodeHeroesDecisionActionKind,
        clusterID: String,
        decisionIDs: [String],
        queueDigest: String,
        decisionDigests: [String: String],
        selectedOptions: [String: String] = [:],
        comment: String? = nil,
        requestedAt: String,
        mustardRunID: String? = nil
    ) {
        self.schemaVersion = 1
        self.requestID = requestID
        self.action = action
        self.actor = "leon"
        self.clusterID = clusterID
        self.decisionIDs = decisionIDs
        self.queueDigest = queueDigest
        self.decisionDigests = decisionDigests
        self.selectedOptions = selectedOptions
        self.comment = comment
        self.requestedAt = requestedAt
        self.mustardRunID = mustardRunID
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case action, actor
        case clusterID = "cluster_id"
        case decisionIDs = "decision_ids"
        case queueDigest = "queue_digest"
        case decisionDigests = "decision_digests"
        case selectedOptions = "selected_options"
        case comment
        case requestedAt = "requested_at"
        case mustardRunID = "mustard_run_id"
    }
}

/// Result returned by the Code Heroes adapter. Status values intentionally mirror
/// the user-facing lifecycle rather than exposing adapter-internal YAML details.
public struct CodeHeroesDecisionActionResult: Codable, Equatable, Sendable {
    public struct ChildResult: Codable, Equatable, Sendable {
        public let decisionID: String
        public let status: String
        public let message: String

        public init(decisionID: String, status: String, message: String) {
            self.decisionID = decisionID
            self.status = status
            self.message = message
        }

        enum CodingKeys: String, CodingKey {
            case decisionID = "decision_id"
            case status, message
        }
    }

    public let requestID: String
    public let status: String
    public let message: String
    public let clusterID: String?
    public let decisionIDs: [String]
    public let mustardRunID: String?
    public let childResults: [ChildResult]?

    public init(
        requestID: String,
        status: String,
        message: String,
        clusterID: String? = nil,
        decisionIDs: [String] = [],
        mustardRunID: String? = nil,
        childResults: [ChildResult]? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.message = message
        self.clusterID = clusterID
        self.decisionIDs = decisionIDs
        self.mustardRunID = mustardRunID
        self.childResults = childResults
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status, message
        case clusterID = "cluster_id"
        case decisionIDs = "decision_ids"
        case mustardRunID = "mustard_run_id"
        case childResults = "child_results"
    }

    public var isSuccess: Bool { status == "completed" || status == "ignored" }
    public var isComment: Bool { status == "commented" }
    public var isBlocked: Bool { status == "blocked" || status == "conflict" }
}

public enum CodeHeroesDecisionActionError: Error, Equatable, LocalizedError {
    case malformedProjection(String)
    case unsafePath(String)
    case invalidComment

    public var errorDescription: String? {
        switch self {
        case .malformedProjection(let message): message
        case .unsafePath(let path): "Code Heroes source path is unsafe: \(path)"
        case .invalidComment: "Comment adjustment needs a short, non-empty comment."
        }
    }
}

/// Builds requests from a read-only projection and its bounded provenance fields.
public enum CodeHeroesDecisionActionRequestBuilder {
    public static func make(
        task: MustardTask,
        action: CodeHeroesDecisionActionKind,
        comment: String? = nil,
        now: Date = .now,
        runID: String? = UUID().uuidString.lowercased()
    ) throws -> CodeHeroesDecisionActionRequest {
        guard CodeHeroesDecisionPolicy.isProjection(task) else {
            throw CodeHeroesDecisionActionError.malformedProjection("Task is not a Code Heroes decision projection.")
        }
        let context = parseContext(task.sourceContext)
        guard let clusterID = context["cluster"], !clusterID.isEmpty else {
            throw CodeHeroesDecisionActionError.malformedProjection("Projection is missing its cluster ID.")
        }
        guard let queueDigest = context["digest"], queueDigest.hasPrefix("sha256:") else {
            throw CodeHeroesDecisionActionError.malformedProjection("Projection is missing its queue digest; refresh the Code Heroes queue.")
        }
        let decisionIDs = context["source_ids"]?.split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? []
        guard !decisionIDs.isEmpty else {
            throw CodeHeroesDecisionActionError.malformedProjection("Projection is missing its decision source IDs.")
        }
        let normalizedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .comment && (normalizedComment?.isEmpty != false || (normalizedComment?.utf8.count ?? 0) > 2_000) {
            throw CodeHeroesDecisionActionError.invalidComment
        }
        if action != .comment && normalizedComment != nil && !normalizedComment!.isEmpty {
            throw CodeHeroesDecisionActionError.invalidComment
        }
        let repositoryRoot = try repositoryRoot(for: task)
        let decisionDigests = try decisionIDs.reduce(into: [String: String]()) { result, id in
            if let digest = contextDecisionDigests(context)[id] {
                result[id] = digest
                return
            }
            guard let path = decisionPath(for: id, task: task), isWithin(URL(fileURLWithPath: path), root: repositoryRoot) else {
                throw CodeHeroesDecisionActionError.malformedProjection("Decision source \(id) is unavailable; refresh the Code Heroes queue.")
            }
            let decisionURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let decisionsRoot = repositoryRoot.appendingPathComponent("operations/decisions", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard isWithin(decisionURL, root: decisionsRoot),
                  ["open", "resolved"].contains(decisionURL.deletingLastPathComponent().lastPathComponent),
                  decisionURL.pathExtension == "md" else {
                throw CodeHeroesDecisionActionError.unsafePath(path)
            }
            guard let data = FileManager.default.contents(atPath: decisionURL.path) else {
                throw CodeHeroesDecisionActionError.unsafePath(path)
            }
            result[id] = "sha256:\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
        }
        let requestID = "RESP-\(dateStamp(now))-\(String(task.uid.replacingOccurrences(of: "-", with: "").prefix(16)))"
        return .init(
            requestID: requestID,
            action: action,
            clusterID: clusterID,
            decisionIDs: decisionIDs,
            queueDigest: queueDigest,
            decisionDigests: decisionDigests,
            selectedOptions: action == .approveAndRun ? decisionIDs.reduce(into: [:]) { $0[$1] = "__recommended__" } : [:],
            comment: action == .comment ? normalizedComment : nil,
            requestedAt: iso(now),
            mustardRunID: runID
        )
    }

    public static func settings(for task: MustardTask) throws -> CodeHeroesQueueSettings {
        let root = try repositoryRoot(for: task)
        guard let raw = task.sourceURL, let queue = localURL(raw), isWithin(queue, root: root),
              queue.pathExtension == "json",
              queue.deletingLastPathComponent().lastPathComponent == "triage" else {
            throw CodeHeroesDecisionActionError.unsafePath(task.sourceURL ?? "")
        }
        return .init(
            repositoryRoot: root.path,
            queuePath: queue.path,
            enabled: true
        )
    }

    private static func parseContext(_ value: String) -> [String: String] {
        value.split(separator: ";").reduce(into: [:]) { result, segment in
            let parts = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0]] = parts[1]
        }
    }

    private static func contextDecisionDigests(_ context: [String: String]) -> [String: String] {
        guard let raw = context["decision_digests"] else { return [:] }
        return raw.split(separator: ",").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let id = parts[0]
            let digest = parts[1]
            result[id] = digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)"
        }
    }

    private static func decisionPath(for id: String, task: MustardTask) -> String? {
        task.links.first { link in
            link.label == "Decision" && URL(fileURLWithPath: link.url).lastPathComponent == "\(id).md"
        }?.url
    }

    private static func localURL(_ value: String) -> URL? {
        guard value.hasPrefix("/"), URL(string: value)?.scheme == nil else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    public static func repositoryRoot(for task: MustardTask) throws -> URL {
        guard let raw = task.sourceURL, let queue = localURL(raw) else {
            throw CodeHeroesDecisionActionError.unsafePath(task.sourceURL ?? "")
        }
        let resolvedQueue = queue.resolvingSymlinksInPath()
        guard resolvedQueue.pathExtension == "json",
              resolvedQueue.deletingLastPathComponent().lastPathComponent == "triage",
              resolvedQueue.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "decisions",
              resolvedQueue.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "operations" else {
            throw CodeHeroesDecisionActionError.unsafePath(raw)
        }
        return (0..<4).reduce(resolvedQueue) { url, _ in url.deletingLastPathComponent() }
    }

    private static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}

/// Narrow adapter runner. It invokes a fixed repository script with an argument array;
/// no generic Mustard worker or decision text is ever interpreted as shell input.
public protocol CodeHeroesDecisionActionRunning: Sendable {
    func run(
        request: CodeHeroesDecisionActionRequest,
        settings: CodeHeroesQueueSettings
    ) async -> CodeHeroesDecisionActionResult
}

public struct ProductionCodeHeroesDecisionActionRunner: CodeHeroesDecisionActionRunning, Sendable {
    public init() {}

    public func run(
        request: CodeHeroesDecisionActionRequest,
        settings: CodeHeroesQueueSettings
    ) async -> CodeHeroesDecisionActionResult {
        await Task.detached(priority: .userInitiated) {
            Self.runSynchronously(request: request, settings: settings)
        }.value
    }

    private static func runSynchronously(
        request: CodeHeroesDecisionActionRequest,
        settings: CodeHeroesQueueSettings
    ) -> CodeHeroesDecisionActionResult {
        #if !os(macOS)
        // The adapter shells out to Ruby and `Process` is macOS-only. The iOS
        // companion reads the same decision data but never applies a response,
        // so it takes the same "adapter unavailable" path as a missing script.
        return .init(requestID: request.requestID, status: "blocked", message: "Code Heroes response adapter runs on macOS only.", clusterID: request.clusterID, decisionIDs: request.decisionIDs, mustardRunID: request.mustardRunID)
        #else
        let root = URL(fileURLWithPath: settings.repositoryRoot).standardizedFileURL.resolvingSymlinksInPath()
        let script = root.appendingPathComponent("tools/phase6b/decision_response.rb")
        let registry = root.appendingPathComponent("automation/registry/projects.json")
        guard !settings.repositoryRoot.isEmpty,
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: registry.path),
              isWithinRoot(script, root: root),
              isWithinRoot(registry, root: root) else {
            return .init(requestID: request.requestID, status: "blocked", message: "Code Heroes response adapter is not available in this repository.", clusterID: request.clusterID, decisionIDs: request.decisionIDs, mustardRunID: request.mustardRunID)
        }
        let requestURL = root.appendingPathComponent("operations/decisions/responses/requests/\(request.requestID).yml")
        do {
            let data = try JSONEncoder().encode(request)
            try FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: requestURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: requestURL) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
            process.arguments = [script.path, "apply", "--root", root.path, "--registry", registry.path, "--request", requestURL.path]
            process.currentDirectoryURL = root
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let result = try? JSONDecoder().decode(CodeHeroesDecisionActionResult.self, from: output) else {
                let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "adapter process failed"
                return .init(requestID: request.requestID, status: "failed", message: detail.isEmpty ? "Code Heroes adapter process failed." : detail, clusterID: request.clusterID, decisionIDs: request.decisionIDs, mustardRunID: request.mustardRunID)
            }
            return result
        } catch {
            return .init(requestID: request.requestID, status: "failed", message: error.localizedDescription, clusterID: request.clusterID, decisionIDs: request.decisionIDs, mustardRunID: request.mustardRunID)
        }
        #endif
    }

    private static func isWithinRoot(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
