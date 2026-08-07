import SwiftUI
import SwiftData

/// The owner-segmented task board (BAK-79). A single board whose visible columns
/// change with the owner lens (Everyone / Mine / Agent). Pipeline + three attention
/// columns (Needs Approval, Needs You, Needs Review). Recreated from the design handoff; all hex/sizes
/// that Theme lacks (column kind tints) come straight from the handoff.
///
/// Scope note: only the board content right of the existing app sidebar lives here.
public struct BoardView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Environment(AgentTaskCoordinator.self) private var taskAgent
    @Query private var allTasks: [MustardTask]
    @Query(sort: \Area.name) private var areas: [Area]

    @State private var view: BoardOwnerView
    @State private var area: BoardArea = .all
    @State private var selectedTask: MustardTask?
    @State private var reviewFocus = false
    @State private var expandedEmpty: Set<TaskStage> = []
    @State private var dropTargetStage: TaskStage?
    @State private var searchText = ""

    private let settings = BoardSettings()
    private var compact: Bool { settings.compact }
    private var showConfidence: Bool { settings.showConfidence }
    private var columnWidth: CGFloat { compact ? 162 : 182 }

    public init() {
        _view = State(initialValue: BoardSettings().defaultView)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let hint = agent.lastHint { handoffHintBanner(hint) }
            columns
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bg)
        .taskDetailDrawer(item: $selectedTask)
    }

    // MARK: Hand-off hint (BAK-90) — area required before agent hand-off

    private func handoffHintBanner(_ hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Fonts.caption)
            Text(hint).font(Theme.Fonts.meta)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.warnText)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.warnTintSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.warnTintBorder).frame(height: 0.5) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Board")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                let waiting = PersonalBoard.waitingCount(allTasks, view: view, area: area)
                if waiting > 0 || reviewFocus {
                    Button { reviewFocus.toggle() } label: {
                        Text(reviewFocus ? "Exit review queue" : "● \(waiting) waiting on you")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(reviewFocus ? Color.white : Theme.Palette.agentText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(reviewFocus ? AnyShapeStyle(Theme.Palette.agent) : AnyShapeStyle(Theme.Palette.agentTintLight), in: Capsule())
                            .overlay(Capsule().stroke(reviewFocus ? Color.clear : Theme.Palette.agentTintBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(reviewFocus ? "Show the full board." : "Focus the board on just the three attention columns.")
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain).font(Theme.Fonts.meta).frame(width: 120)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.Palette.surface.opacity(0.5), in: Capsule())
                .overlay(Capsule().stroke(Theme.Palette.hairline, lineWidth: 0.5))
                Button(action: makeNewTask) {
                    Label("New task", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.textPrimary).controlSize(.small)
            }

            controls
                .padding(.top, 16)

            HStack(spacing: 6) {
                Text("●").foregroundStyle(Theme.Palette.agent)
                Text(reviewFocus ? "Review queue — everything waiting on you across all three attention columns." : view.caption)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Palette.statusMutedText)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ownerSegmentedControl
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(width: 0.5, height: 22)
            areaChips
        }
    }

    private var ownerSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(Array(BoardOwnerView.allCases.enumerated()), id: \.element.id) { idx, v in
                let active = v == view
                let activeBg = v == .agent ? Theme.Palette.agent : Theme.Palette.textPrimary
                Text(v.label)
                    .font(Theme.Fonts.meta.weight(active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.white : Theme.Palette.statusMutedText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(active ? AnyShapeStyle(activeBg) : AnyShapeStyle(Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { view = v }
                    .overlay(alignment: .trailing) {
                        if idx < BoardOwnerView.allCases.count - 1 {
                            Rectangle().fill(Theme.Palette.divider).frame(width: 0.5)
                        }
                    }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.divider, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var areaChips: some View {
        HStack(spacing: 6) {
            areaChip(label: "All", target: .all)
            ForEach(areas) { a in
                areaChip(label: a.name, target: .area(a.name))
            }
        }
    }

    @ViewBuilder
    private func areaChip(label: String, target: BoardArea) -> some View {
        let active = area == target
        Text(label)
            .font(.system(size: 12, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Theme.Palette.onSurface : Theme.Palette.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(active ? Theme.Palette.chipActive : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.Palette.chipActiveBorder : Color.clear, lineWidth: 0.5))
            .contentShape(Capsule())
            .onTapGesture { area = target }
    }

    // MARK: Columns

    private var columns: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 11) {
                ForEach(reviewFocus ? PersonalBoard.gateStages : PersonalBoard.columns(for: view), id: \.self) { stage in
                    if PersonalBoard.shouldCollapseEmpty(view: view, isEmpty: isColumnEmpty(stage),
                                                         expanded: expandedEmpty.contains(stage), reviewFocus: reviewFocus) {
                        collapsedStrip(stage)
                    } else {
                        column(stage)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private func column(_ stage: TaskStage) -> some View {
        let style = ColumnStyle(stage.kind)
        // The concrete Area backing the current scope, so an agent-lane quick-add can
        // inherit it for a real hand-off. Nil in the All / personal lenses.
        let hostArea: Area? = { if case .area(let name) = area { return areas.first { $0.name == name } }; return nil }()
        let all = PersonalBoard.filterBySearch(
            PersonalBoard.tasks(allTasks, in: stage, view: view, area: area), query: searchText)
        let isDone = stage == .done
        let visible = isDone ? Array(all.prefix(PersonalBoard.doneColumnLimit)) : all
        // Hide the "+N older" tail while searching — those older items aren't filtered.
        let older = (isDone && searchText.isEmpty) ? PersonalBoard.olderDoneCount(allTasks, view: view, area: area) : 0
        let totalCount = isDone ? visible.count + older : all.count

        return VStack(alignment: .leading, spacing: 0) {
            // Always reserve the accent-bar row so every column's header aligns —
            // plain columns just get a transparent bar (the bar height is layout, not decoration).
            RoundedRectangle(cornerRadius: 3)
                .fill(style.accent ?? .clear)
                .frame(height: 3)
                .padding(.horizontal, 2)
                .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stage.label.uppercased())
                        .font(Theme.Fonts.caption.weight(.bold))
                        .tracking(0.04 * 11)
                        .foregroundStyle(style.head)
                    Text("\(totalCount)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textFaint)
                }
                if let sub = stage.subLabel {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 9)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if visible.isEmpty && older == 0 {
                        Text("Drop here")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(Theme.Palette.strikethrough)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                    }
                    ForEach(visible) { task in
                        MustardBoardCard(task: task, showConfidence: showConfidence)
                            .draggable(task.uid)
                            .onTapGesture { selectedTask = task }
                    }
                    if older > 0 {
                        Text("+\(older) older completed")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                    }
                    QuickColumnAdd(stage: stage, boardArea: area, hostArea: hostArea)
                }
            }
        }
        .padding(10)
        .frame(width: columnWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(style.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if dropTargetStage == stage {
                RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { uids, _ in
            guard let uid = uids.first,
                  let task = allTasks.first(where: { $0.uid == uid }) else { return false }
            guard task.stage != stage else { return true }
            // BAK-90: dropping into an agent lane is a hand-off — require a client area
            // first, or the bridge export silently won't route it. Reject + surface a hint.
            if PersonalBoard.isAgentLane(stage) && !PersonalBoard.canHandOffToAgent(task) {
                agent.delegate(task)   // no-ops the hand-off and sets the hint banner
                return false
            }
            // Your own lanes — pulling an agent task into one of these is a take-back.
            let personalLanes: Set<TaskStage> = [.planned, .scheduled, .blocked]
            let hasLiveRun = task.owner == .agent && task.agentRun?.state == .running
            if stage == .done {
                // Cancel a live agent turn through the coordinator before marking its task
                // done, or the running claude process is orphaned and holds the serial slot
                // until it finishes (Task 7 quality review).
                if hasLiveRun { taskAgent.takeBack(task) }
                TaskCompletion.complete(task, in: context)
            } else if task.owner == .agent, personalLanes.contains(stage) || (hasLiveRun && stage == .inbox) {
                // Take-back: route through the coordinator so any live run is cancelled and
                // the slot released, then honour the exact lane it was dropped into. Inbox is
                // a shared lane, but a *running* task dragged there is still a take-back —
                // otherwise its turn would be orphaned exactly like the Done case above.
                taskAgent.takeBack(task)
                if stage != .planned { PersonalBoard.move(task, to: stage) }
                task.owner = .me   // guarantee owner coherence even if takeBack no-ops
            } else {
                // NOTE (Task 10 board-hardening follow-up): dragging a *running* agent task
                // between agent lanes here still does not cancel its turn — the requeue
                // semantics there are a product question, not a mechanical take-back.
                PersonalBoard.move(task, to: stage)
                // Keep owner coherent with the lane dropped into; Inbox/Done are shared.
                switch stage {
                case .forAgent, .needsApproval, .queued, .inProgress, .needsInput, .needsReview:
                    task.owner = .agent
                    agent.clearHint()   // successful hand-off clears any prior hint
                case .planned, .scheduled, .blocked: task.owner = .me
                case .inbox, .done: break
                }
            }
            return true
        } isTargeted: { targeted in
            if targeted { dropTargetStage = stage }
            else if dropTargetStage == stage { dropTargetStage = nil }
        }
    }

    /// Header "+ New task": create an inbox task (owner from the current lens) and open
    /// it in the detail/edit sheet. (BAK-134)
    private func makeNewTask() {
        let t = MustardTask(title: "New task")
        t.stage = .inbox
        t.owner = (view == .agent) ? .agent : .me
        context.insert(t)
        selectedTask = t
    }

    /// True when a column has nothing to show (done also accounts for the "+N older" tail).
    private func isColumnEmpty(_ stage: TaskStage) -> Bool {
        if stage == .done {
            return PersonalBoard.tasks(allTasks, in: .done, view: view, area: area).isEmpty
                && PersonalBoard.olderDoneCount(allTasks, view: view, area: area) == 0
        }
        return PersonalBoard.tasks(allTasks, in: stage, view: view, area: area).isEmpty
    }

    /// Collapsed empty-column strip (Everyone lens) — tap to expand. (BAK-102)
    private func collapsedStrip(_ stage: TaskStage) -> some View {
        let style = ColumnStyle(stage.kind)
        return Button { expandedEmpty.insert(stage) } label: {
            VStack(spacing: 10) {
                Text("0")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textFaint)
                Text(stage.label.uppercased())
                    .font(Theme.Fonts.caption.weight(.bold))
                    .tracking(0.04 * 11)
                    .foregroundStyle(style.head)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(height: 96)
            }
            .frame(width: 40)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 14)
            .background(style.background, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Expand \(stage.label)")
    }
}

/// Visual treatment for a board column, mapped from `TaskColumnKind`. Tints come
/// from `Theme` (canonical token set — BAK-98); the per-kind opacities are the
/// handoff's ("Column styling by kind").
private struct ColumnStyle {
    let background: Color
    let accent: Color?
    let head: Color

    init(_ kind: TaskColumnKind) {
        switch kind {
        case .standard:
            background = Theme.Palette.surface.opacity(0.55)
            accent = nil
            head = Theme.Palette.textSecondary
        case .handoff:
            background = Theme.Palette.agent.opacity(0.05)
            accent = Theme.Palette.agentTintMid
            head = Theme.Palette.agentMid
        case .gate:
            background = Theme.Palette.agent.opacity(0.085)
            accent = Theme.Palette.agent
            head = Theme.Palette.agentText
        case .agent:
            background = Theme.Palette.agent.opacity(0.05)
            accent = Theme.Palette.agentTintStrong
            head = Theme.Palette.agentMid
        case .warn:
            background = Theme.Palette.warning.opacity(0.07)
            accent = Theme.Palette.warning
            head = Theme.Palette.warnText
        case .done:
            background = Theme.Palette.done.opacity(0.05)
            accent = Theme.Palette.doneAccent
            head = Theme.Palette.doneHead
        }
    }
}

/// Per-column "+ Add" affordance. `stage` is the source of truth. Creating into a
/// non-agent column makes a plain `.me` task at that stage; creating into an agent lane
/// is a hand-off — it inherits the board's scoped client area (owner agent) so it will
/// actually export, or, when the board isn't scoped to one area, lands in Planned with a
/// hint rather than stranding area-less in the lane (BAK-90 follow-up).
struct QuickColumnAdd: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    let stage: TaskStage
    /// The board's current area scope, so agent-lane creates can inherit it.
    let boardArea: BoardArea
    /// The concrete Area to attach when handing off (resolved by the parent from the
    /// scoped area). Nil when the board isn't scoped to a single area.
    let hostArea: Area?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textFaint)
            }
            .buttonStyle(.plain)
            TextField("Add…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textFaint)
                .focused($focused)
                .onSubmit(add)
        }
        .padding(.horizontal, 4)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { focused = true; return }
        let placement = PersonalBoard.newTaskPlacement(inColumn: stage, boardArea: boardArea)
        let task = MustardTask(title: trimmed, owner: placement.owner)
        task.stage = placement.stage
        if placement.attachArea, let host = hostArea {
            task.list = listForHandOff(in: host)
            agent.clearHint()
        }
        context.insert(task)
        if placement.blockedHandOff {
            agent.setHint("New agent tasks need a client area — pick an area tab first, "
                + "or hand it off from the card. Saved to Planned for now.")
        }
        text = ""
        focused = true
    }

    /// Reuse an existing list under the area, else create one — so a handed-off quick-add
    /// task carries an area the bridge export can route by (mirrors MeetingTaskSync).
    private func listForHandOff(in area: Area) -> TaskList {
        if let existing = (area.lists ?? []).first { return existing }
        let list = TaskList(name: area.name, area: area)
        context.insert(list)
        return list
    }
}

#if DEBUG
#Preview {
    BoardView()
        .frame(width: 1100, height: 700)
        .modelContainer(PreviewData.container)
        .environment(AgentService(context: PreviewData.container.mainContext))
        .environment(AgentTaskCoordinator(context: PreviewData.container.mainContext))
}
#endif
