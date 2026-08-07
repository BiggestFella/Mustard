import Foundation
import SwiftData

public enum AgentProvider: String, Codable, CaseIterable {
    case claude
    case codex
}

public enum AgentRunState: String, Codable, CaseIterable {
    case queued
    case running
    case needsInput
    case completed
    case failed
    case cancelled
    case interrupted
}

@Model
public final class AgentRun {
    public var uid: String = UUID().uuidString
    public var providerRaw: String = AgentProvider.claude.rawValue
    public var stateRaw: String = AgentRunState.queued.rawValue
    public var providerSessionID: String?
    public var workingDirectory: String = ""
    public var project: String = ""
    public var attemptCount: Int = 0
    public var resumeCount: Int = 0
    public var createdAt: Date = Date.now
    public var startedAt: Date?
    public var lastActivityAt: Date = Date.now
    public var completedAt: Date?
    public var lastOutcomeRaw: String?
    public var lastError: String?
    public var requiresConnectedWorker: Bool = false
    /// When a safe failure is scheduled for a bounded retry, the earliest time the queue
    /// may pick this run up again. `nil` means immediately runnable.
    public var nextAttemptAt: Date?
    /// Consecutive automatic retries spent on the current work; reset when a human drives
    /// a fresh turn (reply / request changes). Bounds the backoff via `AgentRetryPolicy`.
    public var autoRetryCount: Int = 0
    public var task: MustardTask?
    @Relationship(deleteRule: .cascade, inverse: \AgentMessage.run)
    public var messages: [AgentMessage]? = []
    @Relationship(deleteRule: .cascade, inverse: \AgentDraft.run)
    public var drafts: [AgentDraft]? = []

    public var provider: AgentProvider {
        get { AgentProvider(rawValue: providerRaw) ?? .claude }
        set { providerRaw = newValue.rawValue }
    }

    public var state: AgentRunState {
        get { AgentRunState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    public var orderedMessages: [AgentMessage] {
        (messages ?? []).sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.uid < $1.uid
        }
    }

    public init(
        task: MustardTask? = nil,
        workingDirectory: String = "",
        project: String = ""
    ) {
        self.task = task
        self.workingDirectory = workingDirectory
        self.project = project
    }
}
