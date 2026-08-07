import SwiftUI

/// Row density (BAK-245). `condensed` is the default detail-card row; `tighter`
/// shrinks the title and vertical padding so a full day fits without scrolling.
public enum TaskRowDensity {
    case condensed, tighter
    var titleSize: CGFloat { self == .condensed ? 15.5 : 13.5 }
    var vPadding: CGFloat { self == .condensed ? 8 : 5 }
    var rowSpacing: CGFloat { self == .condensed ? 5 : 3 }
}

/// HIGH / URGENT flag — the exact pill the board card uses (BAK-79), shown inline
/// next to a row or card title. Nothing for normal/low priority. Kept as one shared
/// view so a task's flag looks identical as a row, a card, or opened.
public struct PriorityFlag: View {
    let priority: TaskPriority
    public init(priority: TaskPriority) { self.priority = priority }

    public var body: some View {
        switch priority {
        case .high:
            pill("HIGH", fg: Theme.Palette.priorityHighText, bg: Theme.Palette.priorityHighBg)
        case .urgent:
            pill("URGENT", fg: Theme.Palette.priorityUrgentText, bg: Theme.Palette.priorityUrgentBg)
        case .normal, .low:
            EmptyView()
        }
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A small, calm meta pill: an optional SF Symbol + label on the shared muted chip
/// background (the tag-pill look from the board card). The single chip primitive the
/// condensed row is built from, so due / estimate / area / subtask chips all match.
public struct MetaChip: View {
    let systemImage: String?
    let text: String
    let tint: Color

    public init(systemImage: String? = nil, _ text: String, tint: Color = Theme.Palette.textSecondary) {
        self.systemImage = systemImage
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Theme.Fonts.label)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Theme.Palette.statusMutedBg, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.Palette.hairline, lineWidth: 0.5))
    }
}

/// The chip strip for a task row (BAK-245): time · due · estimate · area · agent
/// stage · subtask progress — each shown only when it carries information, in the
/// order approved in the 2026-07-09 mockup. Shared by the desktop and iOS rows so a
/// task reads with the same vocabulary as the detail card. `FlowMeta` (board card)
/// wraps the chips when the row is narrow.
public struct TaskChipRow: View {
    let task: MustardTask
    public init(task: MustardTask) { self.task = task }

    private var isDone: Bool { task.stage == .done }

    /// Short agent-stage label — mirrors the board's DelegationBadge wording.
    private static func agentStage(_ task: MustardTask) -> String? {
        guard task.owner == .agent, task.stage != .done else { return nil }
        switch task.stage {
        case .forAgent: return "For agent"
        case .needsApproval: return "Approve"
        case .queued: return "Queued"
        case .inProgress: return "Working…"
        case .needsInput: return "Needs you"
        case .needsReview: return "Review"
        default: return "Agent"
        }
    }

    /// Whether the task has any chip to show — lets a row skip the strip entirely so a
    /// bare task (untimed, default estimate, no area/subtasks) adds no empty gap.
    public static func hasChips(_ task: MustardTask) -> Bool {
        task.isBlocked
            || (task.isTimed && task.scheduledAt != nil)
            || task.dueAt != nil
            || task.estimateMinutes != 30
            || task.list?.area != nil
            || agentStage(task) != nil
            || task.subtaskProgress.total > 0
    }

    public var body: some View {
        let progress = task.subtaskProgress
        let overdueDue = task.dueAt.map { $0 < .now && !isDone } ?? false
        FlowMeta(spacing: 6) {
            if task.isBlocked {
                MetaChip(systemImage: "exclamationmark.triangle", "Blocked", tint: Theme.Palette.warnText)
            }
            // Time — only when anchored to a specific time (untimed "planned for the
            // day" tasks carry a start-of-day date that would read as 12:00 AM).
            if task.isTimed, let when = task.scheduledAt {
                MetaChip(systemImage: "clock", when.formatted(date: .omitted, time: .shortened))
            }
            if let due = task.dueAt {
                MetaChip(systemImage: "calendar",
                         "Due \(due.formatted(.dateTime.month(.abbreviated).day()))",
                         tint: overdueDue ? Theme.Palette.warnText : Theme.Palette.textSecondary)
            }
            if task.estimateMinutes != 30 {
                MetaChip(systemImage: "timer", "\(task.estimateMinutes)m")
            }
            if let area = task.list?.area {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: area.colorHex)).frame(width: 6, height: 6)
                    Text(area.name)
                }
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Theme.Palette.statusMutedBg, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            }
            if let agentStage = Self.agentStage(task) {
                MetaChip("✦ \(agentStage)", tint: Theme.Palette.agentText)
            }
            if progress.total > 0 {
                MetaChip(systemImage: "checklist", "\(progress.done)/\(progress.total)")
            }
        }
    }
}
