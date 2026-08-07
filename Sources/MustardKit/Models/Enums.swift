import Foundation

/// LEGACY: superseded by `TaskStage`. Retained only so existing stores decode and
/// `BoardMigration` can backfill `stage` from it. Do not use in new code.
public enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case inbox, planned, inProgress, done, someday
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inbox: "Inbox"
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .done: "Done"
        case .someday: "Someday"
        }
    }

    public var isOpen: Bool { self != .done && self != .someday }
}

public enum TaskOwner: String, Codable, CaseIterable, Identifiable {
    case me, agent
    public var id: String { rawValue }
    public var label: String { self == .me ? "Me" : "Agent" }
}

public enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    // Order is the handoff create-form order (Low → Urgent); rawValues are stable.
    case low, normal, high, urgent
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .urgent: "Urgent"
        case .high: "High"
        case .normal: "Normal"
        case .low: "Low"
        }
    }
}

/// Voice-capture cleanup lifecycle (F25, ADR-0011). Stored on
/// `MustardTask.captureStateRaw`; nil there means "not a voice capture".
public enum CaptureState: String, Codable, CaseIterable {
    /// Captured, awaiting the agent cleanup pass.
    case raw
    /// Cleanup applied (title/description/schedule structured).
    case cleaned
    /// Cleanup exhausted its retries — the task stays usable with its raw title.
    case failed
}

public enum Recurrence: String, Codable, CaseIterable, Identifiable {
    case daily, weekdays, weekly, monthly
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}
