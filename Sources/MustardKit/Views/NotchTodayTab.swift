#if os(macOS)
import SwiftUI
import SwiftData

/// Today tab: agenda + progress + empty state, lifted out of the notch shell
/// (`NotchSurface.swift`) when the panel became tabbed. The notch is
/// intentionally dark — explicit hex, never `Theme` (see CLAUDE.md). Renders
/// and dispatches only; every decision lives in `DayPlanner`.
struct NotchTodayTab: View {
    @Environment(\.modelContext) private var context
    @Environment(NotchNavigation.self) private var nav
    @Query private var tasks: [MustardTask]
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]

    private var todayAgenda: [AgendaItem] {
        DayPlanner.agenda(tasks: tasks, events: events, day: .now)
    }

    private var todayProgress: (done: Int, total: Int) {
        DayPlanner.dayProgress(tasks, day: .now)
    }

    private func toggleDone(_ task: MustardTask) {
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            TaskCompletion.complete(task, in: context)
        }
    }

    private func openDetail(_ item: AgendaItem) {
        if case .task(let task) = item.kind {
            nav.pendingTask = task
        }
    }

    var body: some View {
        let items = todayAgenda
        let progress = todayProgress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY · \(Date.now.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.08)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if progress.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(Color(hex: "#5DCAA5"))
                            .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(max(progress.total, 1)))
                    }
                }
                .frame(height: 3)
            }
            if items.isEmpty {
                Text("Nothing scheduled today")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(items) { item in
                            AgendaRow(item: item, onToggleDone: toggleDone, onOpen: { openDetail(item) })
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }
}

/// One row of the notch's TODAY agenda. Tasks toggle done via their status
/// circle and open `TaskDetailSheet` on row tap; events have no done state
/// or detail view — their circle is a static indicator and only "Join" is
/// interactive.
private struct AgendaRow: View {
    let item: AgendaItem
    var onToggleDone: (MustardTask) -> Void
    var onOpen: () -> Void

    private var timeLabel: String {
        guard let time = item.time else { return "Any" }
        return time.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 34, alignment: .leading)

            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white.opacity(0.9))
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                if let tag = item.tagLabel {
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: item.tagColorHex ?? "#B0ACA1"))
                }
            }
            Spacer(minLength: 0)
            if let joinURL = item.joinURL, let url = URL(string: joinURL) {
                Link("Join", destination: url)
                    .font(.system(size: 11)).foregroundStyle(Color(hex: "#6E9FFF"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.kind {
        case .task(let task):
            Button {
                onToggleDone(task)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? .white.opacity(0.3) : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
        case .event:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}
#endif
