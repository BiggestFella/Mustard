import Foundation

public enum AgentTurnOutcome: String, Codable, Equatable, Sendable {
    case completed
    case needsInput = "needs_input"
    case failed
    case cancelled
    case requiresConnectedWorker = "requires_connected_worker"
}

public enum AgentRetryDisposition: String, Codable, Equatable, Sendable {
    case none
    case safe
    case backoff
    case uncertain
}

public struct AgentArtifact: Codable, Equatable, Sendable {
    public let label: String
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

public struct AgentDraftPayload: Codable, Equatable, Sendable {
    public let kind: String
    public let title: String
    public let path: String
    public init(kind: String, title: String, path: String) {
        self.kind = kind; self.title = title; self.path = path
    }
}

public enum AgentDrafts {
    /// A draft path must be relative, escape-free, and confined to the drafts folder.
    /// String-level check only — callers that touch the filesystem must go through
    /// `resolvedDraftURL`, which additionally defeats symlink escapes.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
              trimmed.hasPrefix("_agent/drafts/") else { return false }
        return !trimmed.split(separator: "/").contains("..")
    }

    /// The filesystem-level confinement check: resolve symlinks on both the vault
    /// root and the candidate path and require the REAL location to stay inside
    /// `<root>/_agent/drafts/`. A syntactically safe relative path can still escape
    /// through a symlink planted inside the drafts folder; every read and (crucially)
    /// every autosave write must use the URL this returns, or nothing at all.
    public static func resolvedDraftURL(root: String, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath), !root.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        let draftsRoot = rootURL.appendingPathComponent("_agent/drafts", isDirectory: true)
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(draftsRoot.path + "/") else { return nil }
        return candidate
    }
}

public struct AgentTurnResult: Codable, Equatable, Sendable {
    public let outcome: AgentTurnOutcome
    public let message: String
    public let questions: [String]
    public let summary: String
    public let artifacts: [AgentArtifact]
    public let retryDisposition: AgentRetryDisposition
    public let errorCategory: String?
    public let connectedCapability: String?
    public let drafts: [AgentDraftPayload]?

    public init(
        outcome: AgentTurnOutcome, message: String, questions: [String], summary: String,
        artifacts: [AgentArtifact], retryDisposition: AgentRetryDisposition,
        errorCategory: String?, connectedCapability: String?,
        drafts: [AgentDraftPayload]? = nil
    ) {
        self.outcome = outcome; self.message = message; self.questions = questions
        self.summary = summary; self.artifacts = artifacts; self.retryDisposition = retryDisposition
        self.errorCategory = errorCategory; self.connectedCapability = connectedCapability
        self.drafts = drafts
    }
}

public enum AgentTurnContract {
    public static let jsonSchema = #"""
    {
      "type":"object",
      "additionalProperties":false,
      "properties":{
        "outcome":{"type":"string","enum":["completed","needs_input","failed","cancelled","requires_connected_worker"],"description":"The turn outcome. Outcome-specific fields must follow their property descriptions."},
        "message":{"type":"string"},
        "questions":{"type":"array","items":{"type":"string"},"description":"For needs_input, include at least one nonblank question; otherwise use an empty array."},
        "summary":{"type":"string"},
        "artifacts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"label":{"type":"string"},"url":{"type":"string"}},"required":["label","url"]}},
        "retryDisposition":{"type":"string","enum":["none","safe","backoff","uncertain"]},
        "errorCategory":{"type":["string","null"],"description":"For failed, provide a nonblank error category; otherwise use null."},
        "connectedCapability":{"type":["string","null"],"description":"For requires_connected_worker, provide a nonblank capability; otherwise use null."},
        "drafts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string"},"title":{"type":"string"},"path":{"type":"string"}},"required":["kind","title","path"]}}
      },
      "required":["outcome","message","questions","summary","artifacts","retryDisposition","errorCategory","connectedCapability"]
    }
    """#

    public static func decode(_ text: String) throws -> AgentTurnResult {
        let data = Data(text.utf8)
        try validateNoUnknownProperties(in: data)
        let result = try JSONDecoder().decode(AgentTurnResult.self, from: data)
        try validateOutcomeFields(result)
        return result
    }

    public static func workerContract() throws -> String {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("Mustard_MustardKit.bundle", isDirectory: true) }
            .flatMap(Bundle.init(url:))
        var url = packagedBundle?.url(
            forResource: "MustardAgentContract",
            withExtension: "md"
        )
        #if SWIFT_PACKAGE
        // Dev/test builds resolve the resource from the SwiftPM-synthesized module bundle.
        // `Bundle.module` exists only under SwiftPM; the iOS Xcode companion target — which
        // never runs the CLI worker — has no such bundle and falls through to the error.
        if url == nil {
            url = Bundle.module.url(
                forResource: "MustardAgentContract",
                withExtension: "md",
                subdirectory: "Prompts"
            ) ?? Bundle.module.url(
                forResource: "MustardAgentContract",
                withExtension: "md"
            )
        }
        #endif
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func validateNoUnknownProperties(in data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let requiredResultKeys: Set<String> = [
            "outcome", "message", "questions", "summary", "artifacts",
            "retryDisposition", "errorCategory", "connectedCapability",
        ]
        let optionalResultKeys: Set<String> = ["drafts"]
        let keys = Set(object.keys)
        guard requiredResultKeys.isSubset(of: keys),
              keys.isSubset(of: requiredResultKeys.union(optionalResultKeys)) else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        guard let artifacts = object["artifacts"] as? [[String: Any]] else { return }
        let allowedArtifactKeys: Set<String> = ["label", "url"]
        guard artifacts.allSatisfy({ Set($0.keys).isSubset(of: allowedArtifactKeys) }) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
    }

    private static func validateOutcomeFields(_ result: AgentTurnResult) throws {
        func isBlank(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }

        switch result.outcome {
        case .needsInput:
            guard result.questions.contains(where: { !isBlank($0) }),
                  result.errorCategory == nil,
                  result.connectedCapability == nil
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        case .failed:
            guard result.questions.isEmpty,
                  !isBlank(result.errorCategory),
                  result.connectedCapability == nil
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        case .requiresConnectedWorker:
            guard result.questions.isEmpty,
                  result.errorCategory == nil,
                  !isBlank(result.connectedCapability)
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        case .completed, .cancelled:
            guard result.questions.isEmpty,
                  result.errorCategory == nil,
                  result.connectedCapability == nil
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        }
    }
}
