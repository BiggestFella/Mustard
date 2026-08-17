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

/// Voice-capture drafting lifecycle (F25, ADR-0011 addendum). Stored on
/// `MustardTask.captureStateRaw`; nil there means "not a voice capture".
/// On-device drafting (`VoiceTaskDraftGenerator`) replaced the Claude cleanup
/// queue — `.failed` is unused in production (a generator miss leaves `.raw`).
public enum CaptureState: String, Codable, CaseIterable {
    /// Captured, awaiting on-device title/notes structuring.
    case raw
    /// Draft applied (title/description/schedule structured).
    case cleaned
    /// Leftover from the retired Claude cleanup queue. Do not assign.
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
