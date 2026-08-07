import SwiftUI
import SwiftData

/// Edit/inspect a single task — opened from Today, Board, or Week.
/// Binds directly to the SwiftData model so edits persist live.
public struct TaskDetailSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AgentService.self) private var agent
    @Environment(AgentTaskCoordinator.self) private var taskAgent
    @Bindable var task: MustardTask
    /// Set when hosted in the docked drawer (not a sheet): the drawer owns dismissal,
    /// so close actions call this instead of the sheet-only `@Environment(\.dismiss)`.
    private let onClose: (() -> Void)?
    @Query private var areas: [Area]
    @Query private var lists: [TaskList]
    @Query private var allTasks: [MustardTask]
    @State private var isScheduled: Bool
    @State private var scheduledDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var bodyPreview = false
    @State private var newLinkURL = ""
    /// BAK-95: inline feedback when a hand-off is blocked because the task has no area.
    @State private var gateHint: String?

    /// The Stage/Assignee pickers can hand a task to the agent, but the bridge routes by
    /// area — so, like the "Ask agent" buttons, block a hand-off on an area-less task.
    private static let handOffMessage = "Give this task a List (client area) before handing it to the agent — the bridge routes agent work by area."
    private func gateHandOff() -> Bool {
        guard !PersonalBoard.canHandOffToAgent(task) else { gateHint = nil; return true }
        gateHint = Self.handOffMessage
        return false
    }

    private static let estimates = [15, 30, 45, 60, 90, 120]
    /// Actions the agent can execute for a queued task (excludes create_task/fyi/ignore,
    /// which aren't agent-execute outcomes). Offered in the Action picker.
    private static let agentActions: [RecommendationAction] = [.draftEmail, .draftSlack, .ticket, .vaultNote]

    public init(task: MustardTask, onClose: (() -> Void)? = nil) {
        self.task = task
        self.onClose = onClose
        _isScheduled = State(initialValue: task.scheduledAt != nil)
        _scheduledDate = State(initialValue: task.scheduledAt ?? Self.defaultSlot())
        _hasDue = State(initialValue: task.dueAt != nil)
        _dueDate = State(initialValue: task.dueAt ?? Self.defaultSlot())
    }

    /// Dismiss whether hosted in the docked drawer (onClose) or a sheet fallback.
    private func close() { if let onClose { onClose() } else { dismiss() } }

    private static func defaultSlot() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    agentContext
                    // The durable agent conversation + reply/review controls (Task 11).
                    // All its commands route through AgentTaskCoordinator.
                    if task.agentRun != nil { AgentConversationView(task: task) }

                    if let run = task.agentRun, !(run.drafts ?? []).isEmpty {
                        AgentDraftsSection(run: run)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Details")
                        PropertyRow(label: "Stage") {
                            Picker("", selection: Binding(
                                get: { task.stage },
                                set: { newStage in
                                    // Moving into an agent lane is a hand-off — gate it.
                                    if PersonalBoard.isAgentLane(newStage), !gateHandOff() { return }
                                    task.stage = newStage
                                }
                            )) {
                                ForEach(TaskStage.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        PropertyRow(label: "Priority") {
                            Picker("", selection: $task.priority) {
                                ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        PropertyRow(label: "Assignee") {
                            Picker("", selection: Binding(
                                get: { task.owner },
                                set: { newOwner in
                                    if newOwner == .agent, !gateHandOff() { return }
                                    // Switching an agent task back to you is a take-back:
                                    // route it through the coordinator so the run is cancelled
                                    // and the slot released rather than mutating owner directly.
                                    if newOwner == .me, task.owner == .agent {
                                        taskAgent.takeBack(task)
                                        return
                                    }
                                    task.owner = newOwner
                                }
                            )) {
                                ForEach(TaskOwner.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                                .tint(task.owner == .agent ? Theme.Palette.agent : Theme.Palette.accent)
                        }
                        if let gateHint {
                            HStack(spacing: 6) {
                                Image(systemName: "lock").font(Theme.Fonts.caption)
                                Text(gateHint).font(Theme.Fonts.meta)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Theme.Palette.warnText)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Theme.Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        PropertyRow(label: "Action") {
                            // What the agent does when it executes this task. A queued
                            // task must have one set or the bridge can't route it (BAK-89).
                            Picker("", selection: Binding(
                                get: { task.actionType },
                                set: { task.actionType = $0 }
                            )) {
                                Text("None").tag(RecommendationAction?.none)
                                ForEach(Self.agentActions) { Text($0.label).tag(RecommendationAction?.some($0)) }
                            }.labelsHidden().fixedSize()
                        }
                        PropertyRow(label: "Due") {
                            HStack {
                                Toggle("", isOn: $hasDue).labelsHidden().toggleStyle(.switch)
                                    .onChange(of: hasDue) { _, on in task.dueAt = on ? dueDate : nil }
                                if hasDue {
                                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                                        .labelsHidden()
                                        .onChange(of: dueDate) { _, d in task.dueAt = d }
                                }
                            }
                        }
                        PropertyRow(label: "Scheduled") {
                            HStack {
                                Toggle("", isOn: $isScheduled).labelsHidden().toggleStyle(.switch)
                                    .onChange(of: isScheduled) { _, on in
                                        task.scheduledAt = on ? scheduledDate : nil
                                        task.isTimed = on
                                        PersonalBoard.normalizePlacement(task)
                                    }
                                if isScheduled {
                                    // Picking a specific time anchors the task to the week's time axis.
                                    DatePicker("", selection: $scheduledDate)
                                        .labelsHidden()
                                        .onChange(of: scheduledDate) { _, d in
                                            task.scheduledAt = d
                                            task.isTimed = true
                                            PersonalBoard.normalizePlacement(task)
                                        }
                                }
                            }
                        }
                        PropertyRow(label: "Estimate") {
                            Picker("", selection: $task.estimateMinutes) {
                                ForEach(Self.estimates, id: \.self) { Text("\($0)m").tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        PropertyRow(label: "Parent") {
                            ParentPicker(task: task, candidates: allTasks)
                        }
                        PropertyRow(label: "Blocked by") {
                            BlockedByPicker(task: task, candidates: allTasks)
                        }
                        PropertyRow(label: "Recurrence") {
                            Picker("", selection: Binding(
                                get: { task.recurrence },
                                set: { task.recurrence = $0 }
                            )) {
                                Text("None").tag(Recurrence?.none)
                                ForEach(Recurrence.allCases) { Text($0.label).tag(Recurrence?.some($0)) }
                            }.labelsHidden().fixedSize()
                        }
                        PropertyRow(label: "Tags") {
                            TagChipInput(tags: $task.tags)
                        }
                        PropertyRow(label: "Blocked reason") {
                            TextField("reason (optional)", text: $task.blockedReason)
                                .textFieldStyle(.plain).font(Theme.Fonts.meta)
                        }
                        PropertyRow(label: "In") {
                            Picker("", selection: $task.list) {
                                Text("None").tag(TaskList?.none)
                                ForEach(AreaOrganizer.sortedAreas(areas)) { area in
                                    Section(area.name.isEmpty ? "Untitled area" : area.name) {
                                        ForEach(AreaOrganizer.sortedLists(area.lists ?? [])) { list in
                                            Text(list.name.isEmpty ? "Untitled list" : list.name)
                                                .tag(TaskList?.some(list))
                                        }
                                    }
                                }
                                let loose = AreaOrganizer.areaLessLists(lists)
                                if !loose.isEmpty {
                                    Section("No area") {
                                        ForEach(loose) { list in
                                            Text(list.name.isEmpty ? "Untitled list" : list.name)
                                                .tag(TaskList?.some(list))
                                        }
                                    }
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }

                    sectionDivider
                    subtasksSection
                    sectionDivider
                    linksSection
                    sectionDivider
                    bodySection
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            Divider().overlay(Theme.Palette.hairline)
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.bg)
    }

    // Designed header (BAK-244): stage badge + owner on top, a large editable title
    // with the inline priority flag, then the at-a-glance chip strip shared with the
    // row/card (BAK-245). The sheet stays live-edit — the title is a plain field and
    // every DETAILS control below mutates the task directly.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stageBadge
                Text(task.owner == .agent ? "✦ Agent" : "You")
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                SourceLinkButton(task: task)
                Button("Done") { close() }.controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PriorityFlag(priority: task.priority)
                TextField("Title", text: $task.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.docH1)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            if TaskChipRow.hasChips(task) { TaskChipRow(task: task) }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private var stageBadge: some View {
        Text(task.stage.label.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.06)
            .foregroundStyle(stageBadgeColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(stageBadgeColor.opacity(0.14), in: Capsule())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.06)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private var sectionDivider: some View {
        Divider().overlay(Theme.Palette.hairline).padding(.vertical, 2)
    }

    // Stage-adaptive footer (BAK-136): Delete stays leading (this sheet is also the
    // editor); the stage-specific matrix sits trailing. Forward gate actions reuse
    // PersonalBoard.approveTarget/move — no forked state machine.
    private var footer: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                context.delete(task); close()
            } label: { Label("Delete task", systemImage: "trash") }
            .controlSize(.small)
            Spacer()
            stageActions
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var stageActions: some View {
        switch task.stage {
        case .needsApproval:
            Button("I'll do it") { takeOver() }.controlSize(.small)
            Button("Deny", role: .destructive) { context.delete(task); close() }.controlSize(.small)
            Button(task.isGated ? "Approve & run" : "Approve") { approveGate() }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.agent).controlSize(.small)
        case .needsReview:
            Button("Discard", role: .destructive) { context.delete(task); close() }.controlSize(.small)
            if task.agentRun == nil {
                // Legacy tasks without a conversation keep the shared state-machine controls;
                // run-backed tasks get accept / request-changes / take-back in the
                // conversation view, which routes through the coordinator.
                Button("Request changes") { PersonalBoard.move(task, to: .queued) }.controlSize(.small)
                Button("Accept output") { TaskCompletion.complete(task, in: context); close() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.done).controlSize(.small)
            }
        case .needsInput:
            // Answering happens in the conversation view above; the footer offers take-back.
            Button("Take back") { takeOver() }.controlSize(.small)
        case .queued:
            Button("Hold") { PersonalBoard.move(task, to: .needsApproval) }.controlSize(.small)
            Button("Move to review") { PersonalBoard.move(task, to: .needsReview) }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.agent).controlSize(.small)
        case .forAgent:
            Button("Take back") { takeOver() }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.accent).controlSize(.small)
        case .inbox where task.isProposed:
            Button("I'll do it") { takeOver() }.controlSize(.small)
            Button("Schedule") { scheduleTomorrow() }.controlSize(.small)
            Button("Dismiss", role: .destructive) { context.delete(task); close() }.controlSize(.small)
            Button("Approve") { PersonalBoard.move(task, to: .needsApproval) }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.agent).controlSize(.small)
        case .done:
            EmptyView()
        default:
            // Your own open tasks (inbox/planned/scheduled/inProgress/blocked).
            if task.owner == .me && task.delegation == nil {
                Button { agent.delegate(task) } label: { Label("Hand to ✦ agent", systemImage: "cpu") }
                    .tint(Theme.Palette.agent).controlSize(.small)
                    .help("Hand this task to the agent — it proposes how to do it, then runs per your trust level.")
            }
            Button("Mark done") { TaskCompletion.complete(task, in: context); close() }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.done).controlSize(.small)
        }
    }

    /// Take a task back to yourself as planned work. Agent-owned work routes through the
    /// coordinator so any active run is cancelled and the local slot is released; genuinely
    /// local tasks fall back to a direct reassignment.
    private func takeOver() {
        if task.owner == .agent {
            taskAgent.takeBack(task)
        } else {
            task.owner = .me
            if task.stage.isOpen { task.stage = .planned }
        }
    }

    /// Approve a gate using the shared state machine (needsApproval → queued/needsReview).
    private func approveGate() {
        if let target = PersonalBoard.approveTarget(for: task) { PersonalBoard.move(task, to: target) }
    }

    /// Schedule a proposed task for tomorrow 9am as your own planned/scheduled work.
    private func scheduleTomorrow() {
        // Scheduling a proposed agent task is a take-back: cancel any run and release the
        // slot through the coordinator before it becomes your own scheduled work.
        if task.owner == .agent { taskAgent.takeBack(task) }
        task.owner = .me
        let cal = Calendar.current
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) {
            task.scheduledAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
        task.isTimed = false
        task.stage = .scheduled
    }

    // Links referenced by the task (BAK-91) — e.g. a Shortcut story / Jira issue carried
    // from a create_task rec, or one added by hand. Show, open, remove, add.
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Links")
            ForEach(task.links, id: \.url) { link in
                HStack(spacing: 8) {
                    Button {
                        if let u = URL(string: link.url) { openURL(u) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link").font(Theme.Fonts.caption)
                            Text(link.label).font(Theme.Fonts.meta)
                            Text(link.url).font(Theme.Fonts.meta)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
                    Spacer(minLength: 0)
                    Button { task.links.removeAll { $0.url == link.url } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textTertiary)
                    .help("Remove link")
                }
            }
            HStack(spacing: 6) {
                TextField("Add a link (URL)…", text: $newLinkURL)
                    .textFieldStyle(.plain).font(Theme.Fonts.meta).onSubmit(addLink)
                Button(action: addLink) {
                    Image(systemName: "plus").font(Theme.Fonts.meta)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Append a manually-entered link (http/https only), de-duplicated, labelled by host.
    private func addLink() {
        let trimmed = newLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        defer { newLinkURL = "" }
        guard !task.links.contains(where: { $0.url == trimmed }) else { return }
        task.links.append(TaskLink(label: TaskLinkExtractor.label(for: url), url: trimmed))
    }

    /// Read-only agent-context (BAK-137): the approval-panel info — stage badge, gated
    /// notice, confidence, WHY, and the proposed draft — surfaced when the task carries
    /// agent context. (No separate read/edit mode: the sheet shows context + remains editable.)
    @ViewBuilder private var agentContext: some View {
        let conf = task.confidence
        let why = task.delegation?.reasoning ?? ""
        let draft = task.delegation?.draft ?? ""
        if conf != nil || !why.isEmpty || !draft.isEmpty || task.isGated {
            VStack(alignment: .leading, spacing: 10) {
                if task.isGated {
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(Theme.Fonts.caption)
                        Text("Gated action — always reviewed by you, whatever the trust level.")
                            .font(Theme.Fonts.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.Palette.agentText)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.Palette.agentTintLight, in: RoundedRectangle(cornerRadius: 8))
                }
                if let conf {
                    HStack(spacing: 8) {
                        Text("CONFIDENCE").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(String(format: "%.2f", conf))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.confidenceColor(conf))
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(i < Int((conf * 5).rounded(.down)) ? Theme.confidenceColor(conf) : Theme.Palette.confidenceUnfilled)
                                    .frame(width: 16, height: 5)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !why.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHY").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(why).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if !draft.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DRAFT").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(draft).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.Palette.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var stageBadgeColor: Color {
        task.owner == .agent ? Theme.Palette.agentText : Theme.Palette.textSecondary
    }

    private var subtasksSection: some View {
        let progress = task.subtaskProgress
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subtasks (\(progress.done)/\(progress.total))")
            ForEach(task.subtasks ?? []) { sub in
                HStack(spacing: 8) {
                    Button {
                        if sub.stage == .done { sub.stage = .planned; sub.completedAt = nil }
                        else { sub.markDone() }
                    } label: {
                        Image(systemName: sub.stage == .done ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(sub.stage == .done ? Theme.Palette.done : Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    Text(sub.title).font(Theme.Fonts.meta)
                        .strikethrough(sub.stage == .done, color: Theme.Palette.textTertiary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer(minLength: 0)
                    Button { context.delete(sub) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove subtask")
                }
            }
            Button {
                let child = MustardTask(title: "New subtask")
                child.parent = task
                context.insert(child)
            } label: {
                Label("Add subtask", systemImage: "plus").font(Theme.Fonts.meta)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Body")
                Spacer()
                Picker("", selection: $bodyPreview) {
                    Text("edit").tag(false)
                    Text("preview").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize().controlSize(.small)
            }
            if bodyPreview {
                // Agent output lands in `notes` (a Needs Review task carries the run's
                // markdown — ADR-0010), so preview block-renders it via the shared
                // notes renderer at reading size. No wikilink graph here → no-ops.
                MarkdownBlocksView(content: task.notes,
                                   resolve: { _ in nil }, onWikilinkTap: { _ in },
                                   bodyFont: Theme.Fonts.reading)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            } else {
                TextEditor(text: $task.notes)
                    .font(Theme.Fonts.body).frame(minHeight: 90, maxHeight: 220).padding(6)
                    .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline))
            }
        }
    }

}
