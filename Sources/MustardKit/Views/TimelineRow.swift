import SwiftUI

/// A simple agent badge derived from the task's board `stage` (ADR-0010 replaced
/// the derived DelegationPhase with the explicit stage). Shown only for agent-owned
/// tasks; tinted with the agent purple. Kept named `DelegationBadge` so existing
/// Week/Board callers still compile.
struct DelegationBadge: View {
    let task: MustardTask

    /// Short stage label for an agent-owned task; nil = no badge (e.g. done).
    private var stageLabel: String? {
        guard task.owner == .agent else { return nil }
        switch task.stage {
        case .forAgent: return "For agent"
        case .needsApproval: return "Approve"
        case .queued: return "Queued"
        case .inProgress: return "Working…"
        case .needsInput: return "Needs you"
        case .needsReview: return "Review"
        case .done: return nil
        default: return "Agent"
        }
    }

    var body: some View {
        if let label = stageLabel {
            Label(label, systemImage: "cpu")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.agent)
        }
    }
}

/// A task rendered as a condensed version of the detail card (BAK-245, approved
/// 2026-07-09): circle checkbox · bold title with an inline HIGH/URGENT flag · a
/// wrapping strip of pill chips (time · due · estimate · area · agent stage ·
/// subtask progress). Shared by Today and the list views; hovering warms the row
/// into a panel to signal the tap target that opens the detail sheet.
public struct TimelineRow: View {
    @Environment(AgentService.self) private var agent
    @State private var hovering = false
    let task: MustardTask
    let density: TaskRowDensity
    var onToggleDone: () -> Void
    var onOpen: () -> Void

    public init(task: MustardTask, density: TaskRowDensity = .condensed,
                onToggleDone: @escaping () -> Void, onOpen: @escaping () -> Void = {}) {
        self.task = task
        self.density = density
        self.onToggleDone = onToggleDone
        self.onOpen = onOpen
    }

    private var isDone: Bool { task.stage == .done }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggleDone) {
                Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isDone ? Theme.Palette.done
                                     : (task.owner == .agent ? Theme.Palette.agent : Theme.Palette.textTertiary))
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriorityFlag(priority: task.priority)
                    Text(task.title)
                        .font(.system(size: density.titleSize, weight: isDone ? .regular : .semibold))
                        .foregroundStyle(isDone ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .strikethrough(isDone, color: Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if TaskChipRow.hasChips(task) {
                    TaskChipRow(task: task)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, density.vPadding)
        .padding(.horizontal, 8)
        .background(hovering ? Theme.Palette.titleBar : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.rMd))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.settle, value: hovering)
        .contextMenu {
            if task.owner == .me && task.delegation == nil && task.stage != .done {
                Button { agent.delegate(task) } label: {
                    Label("Ask agent to do this", systemImage: "cpu")
                }
            }
        }
    }
}
