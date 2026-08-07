import SwiftUI
import SwiftData

/// The filtered content for a selected list (or the Unfiled bucket): a header,
/// the tasks, and a quick-add that files new tasks into the list. Mirrors
/// TodayView's structure and reuses TimelineRow + TaskDetailSheet.
struct ListContentView: View {
    @Environment(\.modelContext) private var context
    let scope: ListScope
    @Query private var allTasks: [MustardTask]
    @State private var selectedTask: MustardTask?
    @State private var showCompleted = false

    private var tasks: [MustardTask] {
        switch scope {
        case .unfiled: return AreaOrganizer.unfiled(allTasks)
        case .list(let list): return AreaOrganizer.tasks(in: list, from: allTasks)
        }
    }

    private var active: [MustardTask] { AreaOrganizer.active(tasks) }
    private var completed: [MustardTask] { AreaOrganizer.completed(tasks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(active) { task in
                        TimelineRow(task: task, onToggleDone: { toggle(task) }, onOpen: { selectedTask = task })
                        Divider().overlay(Theme.Palette.hairline)
                    }
                }
                if active.isEmpty {
                    Text(scope.isUnfiled ? "Nothing unfiled." : "No tasks in this list yet.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.vertical, 16)
                }
                QuickCaptureField(fileInto: scope.listValue)
                completedSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.bg)
        .taskDetailDrawer(item: $selectedTask)
    }

    private var header: some View {
        HStack(spacing: 10) {
            switch scope {
            case .unfiled:
                Image(systemName: "tray").foregroundStyle(Theme.Palette.textTertiary)
                Text("Unfiled")
                    .font(Theme.Fonts.header).foregroundStyle(Theme.Palette.textPrimary)
            case .list(let list):
                Circle()
                    .fill(Color(hex: list.area?.colorHex ?? Theme.Palette.areaGreyHex))
                    .frame(width: 10, height: 10)
                Text(list.name.isEmpty ? "Untitled list" : list.name)
                    .font(Theme.Fonts.header).foregroundStyle(Theme.Palette.textPrimary)
                if let area = list.area {
                    Text(area.name)
                        .font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.bottom, 12)
    }

    /// Completed tasks, hidden behind a disclosure so a long backlog of done
    /// work stays out of the way until you ask for it.
    @ViewBuilder private var completedSection: some View {
        if !completed.isEmpty {
            Button {
                withAnimation(Theme.Motion.easeInOut(0.15)) { showCompleted.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Completed (\(completed.count))")
                        .font(Theme.Fonts.meta)
                    Spacer()
                }
                .foregroundStyle(Theme.Palette.textTertiary)
                .contentShape(Rectangle())
                .padding(.top, 24)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if showCompleted {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(completed) { task in
                        TimelineRow(task: task, onToggleDone: { toggle(task) }, onOpen: { selectedTask = task })
                        Divider().overlay(Theme.Palette.hairline)
                    }
                }
            }
        }
    }

    private func toggle(_ task: MustardTask) {
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            task.markDone()
        }
    }
}
