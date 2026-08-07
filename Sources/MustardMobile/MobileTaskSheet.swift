import SwiftUI
import SwiftData

/// Shared task-detail bottom sheet (the task half of BAK-115), presented from Today /
/// Board / Week. Read-oriented (no edit form on mobile — desktop only); interactive
/// subtasks + a compact stage-adaptive footer that reuses the tested state machine.
struct MobileTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var task: MustardTask

    private var isAgent: Bool { task.owner == .agent }

    /// The latest agent question, when the task is waiting on you.
    private var agentQuestion: String? {
        task.agentRun?.orderedMessages.last { $0.role == .agent && $0.kind == .question }?.content
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(task.stage.label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isAgent ? Theme.Palette.agentText : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((isAgent ? Theme.Palette.agentText : .gray).opacity(0.14), in: Capsule())
                        if task.isGated {
                            Label("Gated", systemImage: "lock").font(.caption2)
                                .foregroundStyle(Theme.Palette.agentText)
                        }
                        Spacer()
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PriorityFlag(priority: task.priority)
                        Text(task.title).font(.title2.bold())
                    }
                    // At-a-glance chips shared with the desktop sheet + rows (BAK-244/245).
                    if TaskChipRow.hasChips(task) { TaskChipRow(task: task) }
                    if !task.notes.isEmpty {
                        Text(task.notes).font(.subheadline).foregroundStyle(.secondary)
                    }

                    if let conf = task.confidence { confidence(conf) }
                    if let why = task.delegation?.reasoning, !why.isEmpty { section("WHY", why) }
                    if let draft = task.delegation?.draft, !draft.isEmpty { section("DRAFT", draft) }
                    // Needs You: mobile can't run the CLI, so it shows the question read-only
                    // and points back to the Mac (live reply awaits CloudKit sync).
                    if task.stage == .needsInput, let question = agentQuestion {
                        section("AGENT NEEDS YOU", question)
                        Text("Reply on Mac to resume.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    details
                    if !task.tags.isEmpty { tags }
                    if !(task.subtasks ?? []).isEmpty { subtasks }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func confidence(_ c: Double) -> some View {
        HStack(spacing: 6) {
            Text("CONFIDENCE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(String(format: "%.2f", c)).font(.caption.weight(.medium)).foregroundStyle(Theme.confidenceColor(c))
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < Int((c * 5).rounded(.down)) ? Theme.confidenceColor(c) : Theme.Palette.confidenceUnfilled)
                        .frame(width: 16, height: 5)
                }
            }
        }
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DETAILS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            detailRow("Assignee", isAgent ? "✦ Agent" : "You")
            detailRow("Priority", task.priority.label)
            if let area = task.list?.area { detailRow("Area", area.name) }
            detailRow("Estimate", "\(task.estimateMinutes)m")
            if let due = task.dueAt { detailRow("Due", due.formatted(.dateTime.day().month().hour().minute())) }
            if let when = task.scheduledAt { detailRow("Day", when.formatted(.dateTime.weekday().day().month().hour().minute())) }
            if let blocker = task.blockedByTask { detailRow("Blocked by", blocker.title) }
        }
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
            .font(.footnote)
    }

    private var tags: some View {
        HStack {
            ForEach(task.tags.prefix(6), id: \.self) { t in
                Text("#\(t)").font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.Palette.statusMutedBg, in: Capsule())
            }
        }
    }

    private var subtasks: some View {
        let subs = task.subtasks ?? []
        let done = subs.filter { $0.stage == .done }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("SUBTASKS \(done)/\(subs.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(subs) { sub in
                Button {
                    if sub.stage == .done { sub.stage = .planned; sub.completedAt = nil } else { sub.markDone() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sub.stage == .done ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(sub.stage == .done ? Theme.Palette.done : .secondary)
                        Text(sub.title).strikethrough(sub.stage == .done).foregroundStyle(.primary)
                        Spacer()
                    }.font(.subheadline)
                }.buttonStyle(.plain)
            }
        }
    }

    // Compact stage-adaptive footer (mirrors the desktop matrix, BAK-136).
    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch task.stage {
            case .needsApproval:
                Button("Deny", role: .destructive) { context.delete(task); dismiss() }
                Spacer()
                Button(task.isGated ? "Approve & run" : "Approve") { approve() }.buttonStyle(.borderedProminent).tint(Theme.Palette.agent)
            case .needsReview:
                Button("Discard", role: .destructive) { context.delete(task); dismiss() }
                Spacer()
                Button("Accept output") { TaskCompletion.complete(task, in: context); dismiss() }.buttonStyle(.borderedProminent).tint(Theme.Palette.done)
            case .queued:
                Button("Hold") { PersonalBoard.move(task, to: .needsApproval) }
                Spacer()
                Button("Move to review") { PersonalBoard.move(task, to: .needsReview) }.buttonStyle(.borderedProminent).tint(Theme.Palette.agent)
            case .forAgent:
                Spacer()
                Button("Take back") { task.owner = .me; if task.stage.isOpen { task.stage = .planned } }.buttonStyle(.borderedProminent)
            case .needsInput:
                // Mobile take-back stays a direct mutation for now (no CLI/coordinator on
                // iOS; live reply awaits CloudKit sync — see the Task 11 handoff note).
                Text("Reply on Mac to resume.").foregroundStyle(.secondary)
                Spacer()
                Button("Take back") { task.owner = .me; if task.stage.isOpen { task.stage = .planned } }.buttonStyle(.borderedProminent)
            case .done:
                Spacer()
                Button("Reopen") { task.stage = .planned; task.completedAt = nil }
            default:
                Spacer()
                Button("Mark done") { TaskCompletion.complete(task, in: context); dismiss() }.buttonStyle(.borderedProminent).tint(Theme.Palette.done)
            }
        }
        .font(.subheadline)
        .padding()
        .background(.bar)
    }

    private func approve() {
        if let target = PersonalBoard.approveTarget(for: task) { PersonalBoard.move(task, to: target) }
    }
}
