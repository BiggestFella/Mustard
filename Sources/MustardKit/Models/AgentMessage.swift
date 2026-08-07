import Foundation
import SwiftData

public enum AgentMessageRole: String, Codable {
    case human
    case agent
    case system
}

public enum AgentMessageKind: String, Codable {
    case delegation
    case question
    case answer
    case progress
    case result
    case reviewFeedback
    case recovery
    case error
}

@Model
public final class AgentMessage {
    public var uid: String = UUID().uuidString
    public var sequence: Int = 0
    public var roleRaw: String = AgentMessageRole.system.rawValue
    public var kindRaw: String = AgentMessageKind.progress.rawValue
    public var content: String = ""
    public var createdAt: Date = Date.now
    public var links: [TaskLink] = []
    public var providerTurnID: String?
    public var run: AgentRun?

    public var role: AgentMessageRole {
        get { AgentMessageRole(rawValue: roleRaw) ?? .system }
        set { roleRaw = newValue.rawValue }
    }

    public var kind: AgentMessageKind {
        get { AgentMessageKind(rawValue: kindRaw) ?? .progress }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        run: AgentRun? = nil,
        sequence: Int = 0,
        role: AgentMessageRole = .system,
        kind: AgentMessageKind = .progress,
        content: String = "",
        links: [TaskLink] = []
    ) {
        self.run = run
        self.sequence = sequence
        self.roleRaw = role.rawValue
        self.kindRaw = kind.rawValue
        self.content = content
        self.links = links
    }
}
