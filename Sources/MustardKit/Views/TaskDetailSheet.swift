import SwiftUI
import SwiftData

/// Inspect a single task — opened from Today, Board, Week, or the console.
///
/// **Read-first (BAK-244):** a personal task opens as a calm document (header,
/// notes, DETAILS, tags, subtasks). **Edit** flips to the live property grid
/// (bindings still write through to SwiftData). The title completion circle
/// and subtask checkboxes stay live on the read surface so light touches
/// don't require Edit. Untitled / "New task" cards start in the grid.
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
    @State private var isEditing: Bool
    @State private var isScheduled: Bool
    @State private var scheduledDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var bodyPreview = false
    @State private var newLinkURL = ""
    /// BAK-95: inline feedback when a hand-off is blocked because the task has no area.
    @State private var gateHint: String?
    @State private var codeHeroesCommenting = false
    @State private var codeHeroesComment = ""
    @State private var codeHeroesFeedbackMessage: String?

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
        _isEditing = State(initialValue: TaskDetailPresentation.startsInEditMode(title: task.title))
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
        if CodeHeroesDecisionPolicy.isProjection(task) {
            readOnlyProjectionDetail
        } else {
            editableDetail
        }
    }

    private var editableDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing {
                        agentContext
                        agentSession
                        editProperties
                        sectionDivider
                        subtasksSection(showRemove: true)
                        sectionDivider
                        linksSection(editable: true)
                        sectionDivider
                        bodySection
                    } else {
                        readNotes
                        agentContext
                        agentSession
                        readDetails
                        readTags
                        subtasksSection(showRemove: false)
                        readLinks
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            Divider().overlay(Theme.Palette.hairline)
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.bg)
        .animation(Theme.Motion.expand, value: isEditing)
    }

    // MARK: - Header

    /// Read: stage badge · Area · List · Edit · Done (close).
    /// Edit: same chrome; Done leaves the grid and returns to read.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TaskStageBadge(stage: task.stage, owner: task.owner)
                if let location = TaskDetailPresentation.locationLine(for: task) {
                    Text(location)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                SourceLinkButton(task: task)
                if !isEditing {
                    Button("Edit") {
                        withAnimation(Theme.Motion.expand) { isEditing = true }
                    }
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.accent)
                    .buttonStyle(.plain)
                }
                Button("Done") {
                    if isEditing {
                        withAnimation(Theme.Motion.expand) { isEditing = false }
                    } else {
                        close()
                    }
                }
                .controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TaskDetailCompleteCircle(
                    isDone: task.stage == .done,
                    isAgent: task.owner == .agent,
                    enabled: !CodeHeroesDecisionPolicy.isProjection(task),
                    action: toggleComplete
                )
                PriorityFlag(priority: task.priority)
                if isEditing {
                    TextField("Title", text: $task.title)
                        .textFieldStyle(.plain)
                        .font(Theme.Fonts.docH1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                } else {
                    Text(task.title.isEmpty ? "Untitled" : task.title)
                        .font(Theme.Fonts.docH1)
                        .foregroundStyle(task.title.isEmpty
                                         ? Theme.Palette.textTertiary
                                         : Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                }
            }
            if !isEditing {
                TaskDetailGlanceChips(
                    owner: task.owner,
                    dueAt: task.dueAt,
                    scheduledAt: task.scheduledAt,
                    isTimed: task.isTimed,
                    estimateMinutes: task.estimateMinutes,
                    isDone: task.stage == .done
                )
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private func toggleComplete() {
        guard !CodeHeroesDecisionPolicy.isProjection(task) else { return }
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            TaskCompletion.complete(task, in: context)
        }
    }

    // MARK: - Read body

    @ViewBuilder private var readNotes: some View {
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            Button {
                withAnimation(Theme.Motion.expand) { isEditing = true }
            } label: {
                Text("Add notes…")
                    .font(Theme.Fonts.reading)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
        } else {
            MarkdownBlocksView(
                content: task.notes,
                resolve: { _ in nil },
                onWikilinkTap: { _ in },
                bodyFont: Theme.Fonts.reading
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
        }
    }

    private var readDetails: some View {
        let rows = TaskDetailPresentation.detailRows(for: task, calendar: .current)
        return VStack(alignment: .leading, spacing: 0) {
            TaskDetailSectionLabel(title: "Details")
                .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                TaskDetailReadPropertyRow(
                    label: row.label,
                    value: row.value,
                    showDivider: index > 0
                )
            }
        }
    }

    @ViewBuilder private var readTags: some View {
        if !task.tags.isEmpty {
            TaskDetailTagPills(tags: task.tags)
        }
    }

    @ViewBuilder private var readLinks: some View {
        if !task.links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TaskDetailSectionLabel(title: "Links")
                ForEach(task.links, id: \.url) { link in
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var agentSession: some View {
        if task.agentRun != nil { AgentConversationView(task: task) }
        if let run = task.agentRun, !(run.drafts ?? []).isEmpty {
            AgentDraftsSection(run: run)
        }
    }

    /// Read-only agent-context (BAK-137): gated notice, confidence, WHY, draft.
    /// Shown in both read and edit so approval info is never hidden behind Edit.
    @ViewBuilder private var agentContext: some View {
        TaskDetailAgentContextBlock(
            isGated: task.isGated,
            confidence: task.confidence,
            why: task.delegation?.reasoning ?? "",
            draft: task.delegation?.draft ?? ""
        )
    }

    // MARK: - Edit property grid (the previous live-edit form)

    private var editProperties: some View {
        VStack(alignment: .leading, spacing: 12) {
            TaskDetailSectionLabel(title: "Details")
            PropertyRow(label: "Stage") {
                Picker("", selection: Binding(
                    get: { task.stage },
                    set: { newStage in
                        if PersonalBoard.isAgentLane(newStage), !gateHandOff() { return }
                        task.stage = newStage
                        // A scheduled date and Inbox cannot coexist (BAK-246).
                        PersonalBoard.normalizePlacement(task)
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
    }

    private var sectionDivider: some View {
        Divider().overlay(Theme.Palette.hairline).padding(.vertical, 2)
    }

    // MARK: - Footer (BAK-136)

    /// The gate's shared verb pair — one source of truth with the console row and the
    /// board card (`AgentInbox.gate`).
    private var gate: AgentInbox.GateChoice? { AgentInbox.gate(for: task) }

    private var footer: some View {
        HStack(spacing: 8) {
            // Suppressed when `stageActions` already offers the destructive drop.
            // Deny/Discard and this button ran the identical call, so a gate showed
            // two buttons for one action — one of them wearing a trash icon that lied
            // (a meeting task is marked ignored in the ledger, never deleted).
            if gate?.secondary == nil {
                Button(role: .destructive) {
                    deleteTask()
                } label: { Label("Delete task", systemImage: "trash") }
                .controlSize(.small)
            }
            Spacer()
            stageActions
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.Palette.titleBar)
    }

    @ViewBuilder private var stageActions: some View {
        switch task.stage {
        case .needsApproval:
            // Existence triage is a two-outcome decision: Keep (it's mine to do) or
            // Delete. "I'll do it" would be a third word for what Keep already does.
            if !AgentInbox.isExistenceTriage(task) {
                Button("I'll do it") { takeOver() }.controlSize(.small)
            }
            Button(gate?.secondary ?? "Deny", role: .destructive) { deleteTask() }.controlSize(.small)
            Button(gate?.primary ?? "Approve") { approveGate() }
                .buttonStyle(.borderedProminent)
                .tint(AgentInbox.isExistenceTriage(task) ? Theme.Palette.accent : Theme.Palette.agent)
                .controlSize(.small)
        case .needsReview:
            Button(gate?.secondary ?? "Discard", role: .destructive) { deleteTask() }.controlSize(.small)
            if task.agentRun == nil {
                Button("Request changes") { PersonalBoard.move(task, to: .queued) }.controlSize(.small)
                Button("Accept output") { TaskCompletion.complete(task, in: context); close() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.done).controlSize(.small)
            }
        case .needsInput:
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
            Button("Dismiss", role: .destructive) { deleteTask() }.controlSize(.small)
            Button("Approve") { PersonalBoard.move(task, to: .needsApproval) }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.agent).controlSize(.small)
        case .done:
            EmptyView()
        default:
            if task.owner == .me && task.delegation == nil {
                Button { agent.delegate(task) } label: { Label("Hand to ✦ agent", systemImage: "cpu") }
                    .tint(Theme.Palette.agent).controlSize(.small)
                    .help("Hand this task to the agent — it proposes how to do it, then runs per your trust level.")
            }
            Button("Mark done") { TaskCompletion.complete(task, in: context); close() }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.done).controlSize(.small)
        }
    }

    private func takeOver() {
        if task.owner == .agent {
            taskAgent.takeBack(task)
        } else {
            task.owner = .me
            if task.stage.isOpen { task.stage = .planned }
        }
    }

    private func approveGate() {
        if let target = PersonalBoard.approveTarget(for: task) { PersonalBoard.move(task, to: target) }
    }

    private func deleteTask() {
        let vaultRoot = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        if MeetingTaskSync.reject(task, context: context, vaultRoot: vaultRoot) {
            close()
        }
    }

    private func scheduleTomorrow() {
        if task.owner == .agent { taskAgent.takeBack(task) }
        task.owner = .me
        let cal = Calendar.current
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) {
            task.scheduledAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
        // Untimed 9:00 is the "planned for the day" convention (quick capture, ritual).
        task.isTimed = false
        PersonalBoard.normalizePlacement(task)
    }

    // MARK: - Links / subtasks / body (edit)

    private func linksSection(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskDetailSectionLabel(title: "Links")
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
                    if editable {
                        Button { task.links.removeAll { $0.url == link.url } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.Palette.textTertiary)
                        .help("Remove link")
                    }
                }
            }
            if editable {
                HStack(spacing: 6) {
                    TextField("Add a link (URL)…", text: $newLinkURL)
                        .textFieldStyle(.plain).font(Theme.Fonts.meta).onSubmit(addLink)
                    Button(action: addLink) {
                        Image(systemName: "plus").font(Theme.Fonts.meta)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addLink() {
        let trimmed = newLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        defer { newLinkURL = "" }
        guard !task.links.contains(where: { $0.url == trimmed }) else { return }
        task.links.append(TaskLink(label: TaskLinkExtractor.label(for: url), url: trimmed))
    }

    private func subtasksSection(showRemove: Bool) -> some View {
        let progress = task.subtaskProgress
        let subs = task.subtasks ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if !subs.isEmpty || isEditing {
                TaskDetailSectionLabel(title: "Subtasks (\(progress.done)/\(progress.total))")
            }
            ForEach(subs) { sub in
                TaskDetailSubtaskRow(
                    title: sub.title,
                    isDone: sub.stage == .done,
                    showRemove: showRemove,
                    onToggle: {
                        if sub.stage == .done { sub.stage = .planned; sub.completedAt = nil }
                        else { sub.markDone() }
                    },
                    onRemove: { context.delete(sub) }
                )
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
                TaskDetailSectionLabel(title: "Body")
                Spacer()
                Picker("", selection: $bodyPreview) {
                    Text("edit").tag(false)
                    Text("preview").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize().controlSize(.small)
            }
            if bodyPreview {
                MarkdownBlocksView(content: task.notes,
                                   resolve: { _ in nil }, onWikilinkTap: { _ in },
                                   bodyFont: Theme.Fonts.reading)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            } else {
                TextEditor(text: $task.notes)
                    .font(Theme.Fonts.body).frame(minHeight: 150, maxHeight: 320).padding(6)
                    .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: Theme.Metrics.rMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.rMd).stroke(Theme.Palette.hairline))
            }
        }
    }

    // MARK: - Code Heroes read-only projection (unchanged behaviour)

    private var readOnlyProjectionDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TaskStageBadge(stage: task.stage, owner: task.owner)
                    Text(TaskDetailPresentation.ownerGlance(task.owner))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    SourceLinkButton(task: task)
                    Button("Done") { close() }.controlSize(.small)
                }
                CodeHeroesDecisionBadge(task: task)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PriorityFlag(priority: task.priority)
                    Text(task.title)
                        .font(Theme.Fonts.docH1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                }
                if TaskChipRow.hasChips(task) { TaskChipRow(task: task) }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            Divider().overlay(Theme.Palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label {
                        Text(CodeHeroesDecisionPresentation.readOnlyExplanation)
                            .font(Theme.Fonts.meta)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").font(Theme.Fonts.caption)
                    }
                    .foregroundStyle(Theme.Palette.agentText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.agentTintLight, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Repository decision response")
                    .accessibilityHint(CodeHeroesDecisionPresentation.readOnlyExplanation)

                    VStack(alignment: .leading, spacing: 12) {
                        TaskDetailSectionLabel(title: "Details")
                        readOnlyProperty("Stage", task.stage.label)
                        readOnlyProperty("Priority", task.priority.label)
                        readOnlyProperty("Assignee", task.owner.label)
                        readOnlyProperty("Action", "Respond through the Code Heroes adapter")
                        if let due = task.dueAt {
                            readOnlyProperty("Due", due.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let scheduled = task.scheduledAt {
                            readOnlyProperty("Scheduled", scheduled.formatted(date: .abbreviated, time: .shortened))
                        }
                        readOnlyProperty("Estimate", "\(task.estimateMinutes)m")
                        readOnlyProperty("In", task.list?.name ?? "None")
                        readOnlyProperty("Tags", task.tags.isEmpty ? "None" : task.tags.map { "#\($0)" }.joined(separator: "  "))
                    }

                    sectionDivider
                    CodeHeroesDecisionSourceLinks(task: task)
                    sectionDivider
                    VStack(alignment: .leading, spacing: 8) {
                        TaskDetailSectionLabel(title: "Body")
                        MarkdownBlocksView(
                            content: task.notes,
                            resolve: { _ in nil },
                            onWikilinkTap: { _ in },
                            bodyFont: Theme.Fonts.reading
                        )
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }

            Divider().overlay(Theme.Palette.hairline)
            VStack(alignment: .leading, spacing: 8) {
                if codeHeroesCommenting {
                    HStack(spacing: 8) {
                        TextField("What should change?", text: $codeHeroesComment, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        Button("Send comment") {
                            let text = codeHeroesComment
                            Task {
                                await agent.commentCodeHeroes(task, text: text)
                                if task.stage == .needsInput { codeHeroesCommenting = false }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(agent.isExecuting || codeHeroesComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { codeHeroesCommenting = false }
                            .controlSize(.small)
                    }
                } else if task.stage.isOpen {
                    HStack(spacing: 8) {
                        Button("Approve & run") {
                            Task { await agent.approveCodeHeroes(task) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Palette.accent)
                        .controlSize(.small)
                        .disabled(agent.isExecuting)

                        Button("Ignore") {
                            Task { await agent.ignoreCodeHeroes(task) }
                        }
                        .controlSize(.small)
                        .disabled(agent.isExecuting)

                        Button("Comment adjustment") { codeHeroesCommenting = true }
                            .controlSize(.small)
                            .disabled(agent.isExecuting)
                        Spacer(minLength: 0)
                    }
                }
                if CodeHeroesDecisionPolicy.isProjection(task) {
                    HStack(spacing: 8) {
                        Menu {
                            Button { recordCodeHeroesFeedback(.useful) } label: {
                                Label("Useful", systemImage: "hand.thumbsup")
                            }
                            Button { recordCodeHeroesFeedback(.tooNoisy) } label: {
                                Label("Too noisy", systemImage: "speaker.slash")
                            }
                            Button { recordCodeHeroesFeedback(.wrongProject) } label: {
                                Label("Wrong project", systemImage: "arrow.triangle.branch")
                            }
                            Button { recordCodeHeroesFeedback(.alreadyHandled) } label: {
                                Label("Already handled", systemImage: "checkmark.circle")
                            }
                        } label: {
                            Label("Feedback", systemImage: "text.bubble")
                        }
                        .controlSize(.small)
                        if let codeHeroesFeedbackMessage {
                            Text(codeHeroesFeedbackMessage)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.agentText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if agent.isExecuting {
                    Label("Sending response to Code Heroes…", systemImage: "hourglass")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else if task.stage == .needsInput && task.tags.contains(where: { $0 == "response:commented" }) {
                    Label("Comment sent · awaiting revision", systemImage: "text.bubble")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.agentText)
                } else if task.stage == .needsReview {
                    Label("Code Heroes needs a fresh review before another response.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.warnText)
                }
                HStack {
                    Spacer()
                    Button("Close") { close() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.Palette.titleBar)
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.bg)
    }

    private func recordCodeHeroesFeedback(_ signal: CodeHeroesFeedbackSignal) {
        guard let result = agent.recordCodeHeroesFeedback(task, signal: signal) else { return }
        codeHeroesFeedbackMessage = result.candidates.isEmpty
            ? "Feedback saved"
            : "Feedback saved · learning suggestion ready for review"
    }

    private func readOnlyProperty(_ label: String, _ value: String) -> some View {
        PropertyRow(label: label) {
            Text(value)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
        }
    }
}
