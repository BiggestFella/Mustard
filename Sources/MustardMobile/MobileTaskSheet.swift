import SwiftUI
import SwiftData

/// Shared task-detail bottom sheet. Read-first to match the desktop
/// `TaskDetailSheet` (BAK-244): stage badge · location · large title · glance
/// chips · notes · DETAILS · tags · interactive subtasks. **Edit** opens a
/// personal-field grid (title, notes, priority, due, scheduled, estimate, tags).
/// Agent WHY/draft/confidence and the BAK-136 footer stay. Full desktop field
/// parity (parent / blocked-by / list picker / agent assignee) stays Mac-only.
struct MobileTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var task: MustardTask
    @State private var isEditing: Bool
    @State private var isScheduled: Bool
    @State private var scheduledDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var newTag = ""

    private static let estimates = [15, 30, 45, 60, 90, 120]

    /// The latest agent question, when the task is waiting on you.
    private var agentQuestion: String? {
        task.agentRun?.orderedMessages.last { $0.role == .agent && $0.kind == .question }?.content
    }

    init(task: MustardTask) {
        self.task = task
        _isEditing = State(initialValue: TaskDetailPresentation.startsInEditMode(title: task.title))
        _isScheduled = State(initialValue: task.scheduledAt != nil)
        _scheduledDate = State(initialValue: task.scheduledAt ?? Self.defaultSlot())
        _hasDue = State(initialValue: task.dueAt != nil)
        _dueDate = State(initialValue: task.dueAt ?? Self.defaultSlot())
    }

    private static func defaultSlot() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if isEditing {
                        editBody
                    } else {
                        readBody
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            .background(Theme.Palette.bg)
            .safeAreaInset(edge: .bottom) { footer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .animation(Theme.Motion.expand, value: isEditing)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header (shared look with desktop)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TaskStageBadge(stage: task.stage, owner: task.owner)
                if task.isGated {
                    Label("Gated", systemImage: "lock")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.agentText)
                }
                if let location = TaskDetailPresentation.locationLine(for: task) {
                    Text(location)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(isEditing ? "Done editing" : "Edit") {
                    withAnimation(Theme.Motion.expand) { isEditing.toggle() }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
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
                        .font(Theme.Fonts.docH1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                } else {
                    Text(task.title.isEmpty ? "Untitled" : task.title)
                        .font(Theme.Fonts.docH1)
                        .foregroundStyle(task.title.isEmpty
                                         ? Theme.Palette.textTertiary
                                         : Theme.Palette.textPrimary)
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

    // MARK: - Read

    @ViewBuilder private var readBody: some View {
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
            Text(task.notes)
                .font(Theme.Fonts.reading)
                .foregroundStyle(Theme.Palette.onSurfaceSoft)
        }

        TaskDetailAgentContextBlock(
            isGated: task.isGated,
            confidence: task.confidence,
            why: task.delegation?.reasoning ?? "",
            draft: task.delegation?.draft ?? ""
        )

        if task.stage == .needsInput, let question = agentQuestion {
            VStack(alignment: .leading, spacing: 6) {
                TaskDetailSectionLabel(title: "Agent needs you")
                Text(question)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.onSurfaceSoft)
                    .textSelection(.enabled)
                Text("Reply on Mac to resume.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }

        readDetails
        if !task.tags.isEmpty { TaskDetailTagPills(tags: task.tags) }
        subtasks
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

    // MARK: - Edit (personal fields)

    private var editBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                TaskDetailSectionLabel(title: "Notes")
                TextField("Add notes…", text: $task.notes, axis: .vertical)
                    .font(Theme.Fonts.reading)
                    .foregroundStyle(Theme.Palette.onSurfaceSoft)
                    .lineLimit(3...8)
            }

            TaskDetailSectionLabel(title: "Details")
            labeled("Priority") {
                Picker("", selection: $task.priority) {
                    ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            labeled("Due") {
                Toggle("", isOn: $hasDue).labelsHidden()
                    .onChange(of: hasDue) { _, on in task.dueAt = on ? dueDate : nil }
                if hasDue {
                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: dueDate) { _, d in task.dueAt = d }
                }
            }
            labeled("Scheduled") {
                Toggle("", isOn: $isScheduled).labelsHidden()
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
            labeled("Estimate") {
                Picker("", selection: $task.estimateMinutes) {
                    ForEach(Self.estimates, id: \.self) { Text("\($0)m").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                TaskDetailSectionLabel(title: "Tags")
                if !task.tags.isEmpty { TaskDetailTagPills(tags: task.tags) }
                HStack {
                    TextField("+ tag", text: $newTag)
                        .font(Theme.Fonts.meta)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.accent)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            subtasks
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 92, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !task.tags.contains(t) else { newTag = ""; return }
        task.tags.append(t)
        newTag = ""
    }

    private var subtasks: some View {
        let subs = task.subtasks ?? []
        let progress = task.subtaskProgress
        return VStack(alignment: .leading, spacing: 8) {
            if !subs.isEmpty || isEditing {
                TaskDetailSectionLabel(title: "Subtasks (\(progress.done)/\(progress.total))")
            }
            ForEach(subs) { sub in
                TaskDetailSubtaskRow(
                    title: sub.title,
                    isDone: sub.stage == .done,
                    showRemove: isEditing,
                    onToggle: {
                        if sub.stage == .done { sub.stage = .planned; sub.completedAt = nil }
                        else { sub.markDone() }
                    },
                    onRemove: { context.delete(sub) }
                )
            }
            if isEditing {
                Button {
                    let child = MustardTask(title: "New subtask")
                    child.parent = task
                    context.insert(child)
                } label: {
                    Label("Add subtask", systemImage: "plus").font(Theme.Fonts.meta)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    // Compact stage-adaptive footer (mirrors the desktop matrix, BAK-136).
    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch task.stage {
            case .needsApproval:
                Button("Deny", role: .destructive) { deleteTask() }
                Spacer()
                Button(task.isGated || task.owner == .agent ? "Approve & run" : "Approve") { approve() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.agent)
            case .needsReview:
                Button("Discard", role: .destructive) { deleteTask() }
                Spacer()
                Button("Accept output") { TaskCompletion.complete(task, in: context); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.done)
            case .queued:
                Button("Hold") { PersonalBoard.move(task, to: .needsApproval) }
                Spacer()
                Button("Move to review") { PersonalBoard.move(task, to: .needsReview) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.agent)
            case .forAgent:
                Spacer()
                Button("Take back") { task.owner = .me; if task.stage.isOpen { task.stage = .planned } }
                    .buttonStyle(.borderedProminent)
            case .needsInput:
                Text("Reply on Mac to resume.").foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button("Take back") { task.owner = .me; if task.stage.isOpen { task.stage = .planned } }
                    .buttonStyle(.borderedProminent)
            case .done:
                Spacer()
                Button("Reopen") { task.stage = .planned; task.completedAt = nil }
            default:
                Spacer()
                Button("Mark done") { TaskCompletion.complete(task, in: context); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.done)
            }
        }
        .font(Theme.Fonts.meta)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(Theme.Palette.titleBar)
    }

    private func approve() {
        if let target = PersonalBoard.approveTarget(for: task) { PersonalBoard.move(task, to: target) }
    }

    private func deleteTask() {
        let vaultRoot = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        if MeetingTaskSync.reject(task, context: context, vaultRoot: vaultRoot) {
            dismiss()
        }
    }
}
