import SwiftUI

/// Row density (BAK-245). `condensed` is the default detail-card row; `tighter`
/// shrinks the title and vertical padding so a full day (or a Week column) fits.
public enum TaskRowDensity {
    case condensed, tighter
    public var titleSize: CGFloat { self == .condensed ? 15.5 : 13.5 }
    public var vPadding: CGFloat { self == .condensed ? 8 : 5 }
    public var rowSpacing: CGFloat { self == .condensed ? 5 : 3 }
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
/// background (the tag-pill look from the board card and BAK-244 glance chips).
/// The single chip primitive the condensed row is built from.
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

    /// Whether the task has any chip to show — lets a row skip the strip entirely so a
    /// bare task (untimed, default estimate, no area/subtasks) adds no empty gap.
    public static func hasChips(_ task: MustardTask) -> Bool {
        TaskRowPresentation.hasChips(for: task)
    }

    public var body: some View {
        FlowMeta(spacing: 6) {
            ForEach(Array(TaskRowPresentation.chips(for: task).enumerated()), id: \.offset) { _, chip in
                chipView(chip)
            }
        }
    }

    @ViewBuilder private func chipView(_ chip: TaskRowChip) -> some View {
        switch chip {
        case .blocked:
            MetaChip(systemImage: "exclamationmark.triangle", "Blocked", tint: Theme.Palette.warnText)
        case .time(let text):
            MetaChip(systemImage: "clock", text)
        case .due(let text, let overdue):
            MetaChip(systemImage: "calendar", text,
                     tint: overdue ? Theme.Palette.warnText : Theme.Palette.textSecondary)
        case .estimate(let minutes):
            MetaChip(systemImage: "timer", "\(minutes)m")
        case .area(let name, let colorHex):
            HStack(spacing: 4) {
                Circle().fill(Color(hex: colorHex)).frame(width: 6, height: 6)
                Text(name)
            }
            .font(Theme.Fonts.label)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Theme.Palette.statusMutedBg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        case .agentStage(let label):
            MetaChip("✦ \(label)", tint: Theme.Palette.agentText)
        case .subtasks(let done, let total):
            MetaChip(systemImage: "checklist", "\(done)/\(total)")
        }
    }
}
