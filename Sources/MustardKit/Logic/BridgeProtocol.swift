import Foundation

public enum BridgeFolders {
    public static let outbox = "_agent/outbox"
    public static let outboxDone = "_agent/outbox/done"
    public static let results = "_agent/results"
    public static let resultsDone = "_agent/results/done"
    /// Undecodable / empty-uid result files are moved here so they aren't re-scanned
    /// every loop (BAK-84). Non-recursive listings exclude this subdir by the .json filter.
    public static let resultsQuarantine = "_agent/results/quarantine"
}

public enum BridgeCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

/// What Mustard writes to `_agent/outbox/<uid>.json` for the connected session to run.
public struct AgentWorkOrder: Codable, Equatable {
    public var uid: String
    public var mode: String          // "prep" | "execute"
    public var actionType: String    // RecommendationAction raw; "" for prep-to-classify
    public var title: String
    public var body: String
    public var area: String          // e.g. "Digital Licence"
    public var project: String       // KB code, e.g. "DL"
    public var sourceContext: String
    public var links: [TaskLink]
    public var createdAt: Date
    public init(uid: String, mode: String, actionType: String, title: String, body: String,
                area: String, project: String, sourceContext: String, links: [TaskLink], createdAt: Date) {
        self.uid = uid; self.mode = mode; self.actionType = actionType; self.title = title
        self.body = body; self.area = area; self.project = project
        self.sourceContext = sourceContext; self.links = links; self.createdAt = createdAt
    }
}

/// What the connected session writes to `_agent/results/<uid>.json`.
public struct AgentResult: Codable, Equatable {
    public var uid: String
    public var mode: String          // "prep" | "execute"
    public var status: String        // "done" | "failed" | "declined"
    public var actionType: String?   // prep: classified action
    public var title: String?        // prep: refined title
    public var body: String?         // prep: prepared draft
    public var links: [TaskLink]?    // execute: created artifact links
    public var summary: String?
    public var error: String?
    public var drafts: [AgentDraftPayload]?
    public init(uid: String, mode: String, status: String, actionType: String? = nil,
                title: String? = nil, body: String? = nil, links: [TaskLink]? = nil,
                summary: String? = nil, error: String? = nil, drafts: [AgentDraftPayload]? = nil) {
        self.uid = uid; self.mode = mode; self.status = status; self.actionType = actionType
        self.title = title; self.body = body; self.links = links; self.summary = summary; self.error = error
        self.drafts = drafts
    }
}
