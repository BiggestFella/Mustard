import Foundation

public struct AgentTaskRoute: Equatable, Sendable {
    public let project: String
    public let workingDirectory: String

    public init(project: String, workingDirectory: String) {
        self.project = project
        self.workingDirectory = workingDirectory
    }
}

public enum AgentTaskQueue {
    public static func nextRunnable(_ tasks: [MustardTask], now: Date = .now) -> MustardTask? {
        tasks
            .filter {
                $0.owner == .agent
                    && ($0.stage == .forAgent || $0.stage == .queued)
                    && !$0.isBlocked
                    && $0.agentRun?.requiresConnectedWorker != true
                    // Honour a scheduled backoff — a run waiting for its next attempt time
                    // is not yet runnable (AgentRetryPolicy).
                    && !isBackingOff($0, now: now)
            }
            .min(by: precedes)
    }

    private static func isBackingOff(_ task: MustardTask, now: Date) -> Bool {
        guard let nextAttemptAt = task.agentRun?.nextAttemptAt else { return false }
        return nextAttemptAt > now
    }

    /// Sources are considered in settings order; the first eligible source whose
    /// project maps to the task's area is selected.
    ///
    /// `defaultRoute` (F26, ADR-0011 addendum) rescues **area-less** hand-offs — a
    /// voice-routed capture that inferred no client area would otherwise strand in
    /// `.queued` forever (BAK-90) because there is no area to route by. It applies ONLY
    /// when the task has no area: a task that HAS an area but no enabled matching source
    /// is a genuine config gap (the manual-hand-off nudge case) and still returns nil,
    /// so the default can never silently shadow a mis-mapped area.
    public static func route(
        _ task: MustardTask, settings: SourceSettings, defaultRoute: AgentTaskRoute? = nil
    ) -> AgentTaskRoute? {
        guard let areaName = task.list?.area?.name else { return defaultRoute }

        for source in settings.sources {
            guard source.enabled,
                  !source.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AreaMapping.areaName(forProject: source.project) == areaName
            else { continue }

            return AgentTaskRoute(
                project: source.project,
                workingDirectory: source.workingDirectory
            )
        }

        return nil
    }

    private static func precedes(_ lhs: MustardTask, _ rhs: MustardTask) -> Bool {
        let lhsPriority = priorityRank(lhs.priority)
        let rhsPriority = priorityRank(rhs.priority)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.uid < rhs.uid
    }

    private static func priorityRank(_ priority: TaskPriority) -> Int {
        switch priority {
        case .urgent: 0
        case .high: 1
        case .normal: 2
        case .low: 3
        }
    }
}
