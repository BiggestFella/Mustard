import SwiftUI
import SwiftData

/// Mobile Board (BAK-114): vertical stacked sections (one per non-empty stage), NOT
/// horizontal columns. Owner + area filters are shared with Week (MobileFilters). Cards
/// carry inline gate buttons; tap opens the shared task-detail sheet. No drag, no owner
/// toggle (mobile). Reuses the tested PersonalBoard filtering + gate state machine.
struct MobileBoardView: View {
    @Environment(\.modelContext) private var context
    @Query private var allTasks: [MustardTask]
    @Bindable var filters: MobileFilters
    @State private var selected: MustardTask?

    private var waiting: Int {
        PersonalBoard.waitingCount(allTasks, view: filters.owner, area: filters.area)
    }
    private var stages: [TaskStage] { PersonalBoard.columns(for: filters.owner) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ownerChips
                    MobileAreaChips(filters: filters)
                    let nonEmpty = stages.compactMap { stage -> (TaskStage, [MustardTask])? in
                        let t = PersonalBoard.tasks(allTasks, in: stage, view: filters.owner, area: filters.area)
                        return t.isEmpty ? nil : (stage, t)
                    }
                    if nonEmpty.isEmpty {
                        Text("Nothing here").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(nonEmpty, id: \.0) { stage, tasks in
                        section(stage, tasks)
                    }
                }
                .padding()
            }
            .navigationTitle("Board")
            .toolbar {
                if waiting > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("● \(waiting) waiting").font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Palette.agentText)
                    }
                }
            }
            .sheet(item: $selected) { MobileTaskSheet(task: $0) }
        }
    }

    private var ownerChips: some View {
        HStack(spacing: 8) {
            ForEach(BoardOwnerView.allCases) { v in
                chip(v.label, active: filters.owner == v, tint: v == .agent ? Theme.Palette.agent : Theme.Palette.accent) {
                    filters.owner = v
                }
            }
        }
    }

    private func chip(_ label: String, active: Bool, tint: Color = Theme.Palette.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.weight(.medium))
                .foregroundStyle(active ? .white : .secondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(active ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.Palette.surface), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func section(_ stage: TaskStage, _ tasks: [MustardTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(stage.label.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("\(tasks.count)").font(.caption).foregroundStyle(.tertiary)
                if let sub = stage.subLabel {
                    Text("· \(sub)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(tasks) { MobileBoardCard(task: $0, onOpen: { selected = $0 }, onDelete: deleteTask) }
        }
    }

    private func deleteTask(_ task: MustardTask) {
        let vaultRoot = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        _ = MeetingTaskSync.reject(task, context: context, vaultRoot: vaultRoot)
    }
}

/// Mobile board card: priority pill, ✦ Agent label (no owner toggle), title, meta, status
/// pill, and hover-free inline gate buttons on the two gate stages. Tap opens the sheet.
private struct MobileBoardCard: View {
    @Bindable var task: MustardTask
    let onOpen: (MustardTask) -> Void
    let onDelete: (MustardTask) -> Void

    private var stage: TaskStage { task.stage }

    var body: some View {
        // Not a Button: a tappable card whose inner gate Buttons must stay independently
        // tappable. A child Button takes hit-test priority over this .onTapGesture, so
        // tapping a gate button does NOT also open the sheet.
        cardBody
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { onOpen(task) }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if task.priority == .urgent {
                        flag("URGENT", .white, Theme.Palette.priorityUrgentBg)
                    } else if task.priority == .high {
                        flag("HIGH", Theme.Palette.priorityHighText, Theme.Palette.priorityHighBg)
                    }
                    if task.owner == .agent {
                        Text("✦ Agent").font(.caption2.weight(.medium)).foregroundStyle(Theme.Palette.agentText)
                    }
                    if task.isProposed {
                        Text("✦ Proposed").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Palette.agentText)
                    }
                    Spacer(minLength: 0)
                    if task.isGated { Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(task.title).font(.subheadline).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let area = task.list?.area {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: area.colorHex)).frame(width: 6, height: 6)
                        Text(area.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if stage == .needsApproval || stage == .needsReview { gateButtons }
            }
            .padding(11)
            .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            .overlay(alignment: .leading) {
                if task.owner == .agent { Theme.Palette.agent.frame(width: 2.5).clipShape(Capsule()) }
            }
    }

    private func flag(_ t: String, _ fg: Color, _ bg: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold))
            .foregroundStyle(fg).padding(.horizontal, 5).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }

    private var gateButtons: some View {
        HStack(spacing: 8) {
            Button(stage == .needsReview ? "✓ Accept" : (task.isGated || task.owner == .agent ? "✓ Approve & run" : "✓ Approve")) {
                if let target = PersonalBoard.approveTarget(for: task) { PersonalBoard.move(task, to: target) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.Palette.agent, in: RoundedRectangle(cornerRadius: 7))
            Button(stage == .needsReview ? "Discard" : "Deny") { onDelete(task) }
                .font(.caption.weight(.medium)).foregroundStyle(Theme.Palette.error)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}
