import SwiftUI

/// A simple agent badge derived from the task's board `stage` (ADR-0010 replaced
/// the derived DelegationPhase with the explicit stage). Shown only for agent-owned
/// tasks; tinted with the agent purple. Kept named `DelegationBadge` so existing
/// Week/Board callers still compile.
struct DelegationBadge: View {
    let task: MustardTask

    var body: some View {
        if let label = TaskRowPresentation.agentStageLabel(owner: task.owner, stage: task.stage) {
            Label(label, systemImage: "cpu")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.agent)
        }
    }
}

/// A task rendered as a condensed version of the detail card (BAK-245, approved
/// 2026-07-09): circle checkbox · bold title (~15.5pt semibold) with an inline
/// HIGH/URGENT flag · a wrapping strip of pill chips (time · due · estimate ·
/// area · agent stage · subtask progress). Time is a chip — there is no left
/// gutter. Shared by Today, Week, lists, and the iOS companion; hovering warms
/// the row into a panel to signal the tap target that opens the BAK-244 sheet.
public struct TimelineRow: View {
    @Environment(AgentService.self) private var agent
    @State private var hovering = false
    let task: MustardTask
    let density: TaskRowDensity
    let showsDelegateMenu: Bool
    let titleLineLimit: Int?
    var onToggleDone: () -> Void
    var onOpen: () -> Void

    public init(
        task: MustardTask,
        density: TaskRowDensity = .condensed,
        showsDelegateMenu: Bool = true,
        titleLineLimit: Int? = nil,
        onToggleDone: @escaping () -> Void,
        onOpen: @escaping () -> Void = {}
    ) {
        self.task = task
        self.density = density
        self.showsDelegateMenu = showsDelegateMenu
        self.titleLineLimit = titleLineLimit
        self.onToggleDone = onToggleDone
        self.onOpen = onOpen
    }

    private var isDone: Bool { task.stage == .done }
    private var allowsCompletion: Bool { !CodeHeroesDecisionPolicy.isProjection(task) }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if allowsCompletion {
                Button(action: onToggleDone) {
                    Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isDone ? Theme.Palette.done
                                         : (task.owner == .agent ? Theme.Palette.agent : Theme.Palette.textTertiary))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            } else {
                Image(systemName: "lock.fill")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.agentText)
                    .padding(.top, 2)
                    .help("Repository decision — respond through the Code Heroes adapter")
                    .accessibilityLabel("Repository decision response")
                    .accessibilityHint("Completion and reopen are unavailable in Mustard")
            }

            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriorityFlag(priority: task.priority)
                    Text(task.title)
                        .font(.system(size: density.titleSize, weight: isDone ? .regular : .semibold))
                        .foregroundStyle(isDone ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                        .strikethrough(isDone, color: Theme.Palette.textTertiary)
                        .lineLimit(titleLineLimit)
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
        .modifier(DelegateMenuModifier(
            enabled: showsDelegateMenu
                && task.owner == .me
                && task.delegation == nil
                && task.stage != .done,
            delegate: { agent.delegate(task) }
        ))
    }
}

/// Attaches the "Ask agent" menu only when the row owns that action — Week
/// supplies a richer menu of its own, and an empty `.contextMenu` would swallow it.
private struct DelegateMenuModifier: ViewModifier {
    let enabled: Bool
    let delegate: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button(action: delegate) {
                    Label("Ask agent to do this", systemImage: "cpu")
                }
            }
        } else {
            content
        }
    }
}
