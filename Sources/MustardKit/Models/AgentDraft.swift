import Foundation
import SwiftData

public enum AgentDraftKind: String, Codable, CaseIterable {
    case email, message, comment, note, other
}

@Model
public final class AgentDraft {
    public var uid: String = UUID().uuidString
    public var kindRaw: String = AgentDraftKind.note.rawValue
    public var title: String = ""
    /// Path relative to the owning run's `workingDirectory`.
    public var relativePath: String = ""
    public var createdAt: Date = Date.now
    public var run: AgentRun?

    public var kind: AgentDraftKind {
        get { AgentDraftKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public init(run: AgentRun? = nil, kind: AgentDraftKind = .note,
                title: String = "", relativePath: String = "") {
        self.run = run
        self.kindRaw = kind.rawValue
        self.title = title
        self.relativePath = relativePath
    }
}
