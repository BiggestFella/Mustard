import SwiftUI
import SwiftData

/// Week planner v2 (Sunsama/Akiflow/Morgen hybrid): an unscheduled + overdue rail
/// and a Mon–Sun grid. Each day has a light time axis (8am–6pm) where meetings and
/// *timed* tasks anchor and size by duration, plus an ordered list below for
/// *untimed* tasks. Drag a rail task onto a day to schedule it (keeps time-of-day,
/// 9:00 default); drag a day block back to the rail to unschedule.
public struct WeekView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Query private var allTasks: [MustardTask]
    @Query private var events: [CalendarEvent]
    @State private var weekOffset = 0
    @State private var selectedTask: MustardTask?
    @State private var toast: BalanceToast?

    /// A Balance result toast; `moves` non-empty carries an exact-restore Undo.
    private struct BalanceToast: Equatable {
        let id = UUID()
        let message: String
        let moves: [WeekPlanner.BalanceMove]
    }

    // Time axis configuration.
    private let axisStartHour = 8
    private let axisEndHour = 18
    private let hourHeight: CGFloat = 44
    private var perMinute: CGFloat { hourHeight / 60 }
    private var axisSpanMinutes: Int { (axisEndHour - axisStartHour) * 60 }
    private var axisHeight: CGFloat { CGFloat(axisEndHour - axisStartHour) * hourHeight }

    public init() {}

    private let cal = Calendar.current
    private var days: [Date] { WeekPlanner.days(weekOffset: weekOffset) }
    private var unscheduled: [MustardTask] { WeekPlanner.unscheduled(allTasks) }
    private var overdue: [MustardTask] { WeekPlanner.overdue(allTasks) }

    private func dayTasks(_ day: Date) -> [MustardTask] { WeekPlanner.tasks(allTasks, on: day) }
    private func dayEvents(_ day: Date) -> [CalendarEvent] {
        events.filter { cal.isDate($0.start, inSameDayAs: day) }
    }

    /// True when `date`'s time-of-day falls inside the visible 8am–6pm window.
    private func inWindow(_ date: Date) -> Bool {
        let m = WeekPlanner.minutesSinceDayStart(date, dayStartHour: axisStartHour, calendar: cal)
        return m >= 0 && m < axisSpanMinutes
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.hairline)
            HStack(alignment: .top, spacing: 0) {
                rail
                Divider().overlay(Theme.Palette.hairline)
                ForEach(days, id: \.self) { day in
                    dayColumn(day)
                    if day != days.last { Divider().overlay(Theme.Palette.hairline) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bg)
        .taskDetailDrawer(item: $selectedTask)
        .overlay(alignment: .bottom) { toastView }
        .animation(Theme.Motion.easeOut(), value: toast)
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            toast = nil
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            HStack(spacing: 12) {
                Text("✦ \(toast.message)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                if !toast.moves.isEmpty {
                    Button("Undo") { undoBalance(toast.moves) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.agentTintStrong)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.Palette.textPrimary, in: Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// ✦ Balance: flatten Mon–Fri load, then offer an exact Undo.
    private func balance() {
        let monFri = Array(days.prefix(5))
        let plan = WeekPlanner.balance(allTasks, weekdays: monFri, calendar: cal)
        guard !plan.moves.isEmpty else {
            toast = BalanceToast(message: "Your week is already balanced", moves: [])
            return
        }
        for m in plan.moves where allTasks.contains(where: { $0.uid == m.uid }) {
            allTasks.first { $0.uid == m.uid }?.scheduledAt = m.to
        }
        let n = plan.moves.count
        let peak = WeekPlanner.capacityLabel(minutes: plan.peakMinutes)
        toast = BalanceToast(
            message: "Balanced your week · moved \(n) task\(n == 1 ? "" : "s"), peak day now \(peak)",
            moves: plan.moves
        )
    }

    private func undoBalance(_ moves: [WeekPlanner.BalanceMove]) {
        for m in moves {
            allTasks.first { $0.uid == m.uid }?.scheduledAt = m.from
        }
        toast = nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Week").font(Theme.Fonts.header).foregroundStyle(Theme.Palette.textPrimary)
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
            Button("Today") { weekOffset = 0 }
                .buttonStyle(.plain).font(Theme.Fonts.meta)
                .foregroundStyle(weekOffset == 0 ? Theme.Palette.textTertiary : Theme.Palette.accent)
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
            if let first = days.first, let last = days.last {
                Text("\(first.formatted(.dateTime.day().month())) – \(last.formatted(.dateTime.day().month()))")
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Button(action: balance) {
                Text("✦ Balance")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.agentText)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Theme.Palette.agentTintLight, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Let the agent even out your overloaded days.")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !overdue.isEmpty {
                    railSection(title: "OVERDUE", tasks: overdue, accent: Theme.Palette.warning)
                }
                railSection(title: "UNSCHEDULED", tasks: unscheduled, accent: nil)
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
            .padding(12)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surface.opacity(0.4))
        .dropDestination(for: String.self) { uids, _ in
            guard let uid = uids.first, let task = allTasks.first(where: { $0.uid == uid })
            else { return false }
            task.scheduledAt = nil
            task.isTimed = false
            return true
        }
    }

    private func railSection(title: String, tasks: [MustardTask], accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(accent ?? Theme.Palette.textTertiary)
            if tasks.isEmpty {
                Text(title == "UNSCHEDULED" ? "All scheduled" : "")
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textTertiary)
            } else {
                ForEach(tasks) { task in
                    WeekChip(task: task, overdue: accent != nil)
                        .draggable(task.uid)
                        .onTapGesture { selectedTask = task }
                        .contextMenu { menu(for: task) }
                }
            }
        }
    }

    // MARK: - Day column

    private func dayColumn(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let tasks = dayTasks(day)
        let evts = dayEvents(day)
        let axisTasks = tasks.filter { $0.isTimed && ($0.scheduledAt.map(inWindow) ?? false) }
        let axisEvents = evts.filter { !$0.isAllDay && inWindow($0.start) }
        let listTasks = tasks.filter { !($0.isTimed && ($0.scheduledAt.map(inWindow) ?? false)) }
        let listEvents = evts.filter { $0.isAllDay || !inWindow($0.start) }

        let capMinutes = WeekPlanner.capacityMinutes(allTasks, on: day, calendar: cal)
        let tier = WeekPlanner.loadTier(minutes: capMinutes)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Spacer(minLength: 0)
                    Text(WeekPlanner.capacityLabel(minutes: capMinutes))
                        .font(Theme.Fonts.caption.weight(.medium))
                        .foregroundStyle(loadColor(tier))
                }
                loadBar(minutes: capMinutes, tier: tier)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    axis(events: axisEvents, tasks: axisTasks)
                    ForEach(listEvents) { MeetingBlock(event: $0) }
                    ForEach(WeekPlanner.groupByTimeOfDay(listTasks, calendar: cal), id: \.0) { group in
                        Text(group.0.label.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.08 * 9)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.top, 2)
                        ForEach(group.1) { task in
                            WeekBlock(task: task,
                                      onOpen: { selectedTask = task },
                                      onToggle: { toggle(task) })
                                .draggable(task.uid)
                                .contextMenu { menu(for: task) }
                        }
                    }
                    QuickCaptureField(scheduleOnto: day, placeholder: "Add…")
                }
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isToday ? Theme.Palette.accent.opacity(0.05) : .clear)
        .dropDestination(for: String.self) { uids, _ in
            guard let uid = uids.first, let task = allTasks.first(where: { $0.uid == uid })
            else { return false }
            task.scheduledAt = WeekPlanner.scheduleDate(on: day, keepingTimeFrom: task.scheduledAt)
            PersonalBoard.normalizePlacement(task)
            return true
        }
    }

    /// Load-bar colour by tier (handoff: green / amber / red).
    private func loadColor(_ tier: WeekPlanner.LoadTier) -> Color {
        switch tier {
        case .green: Theme.Palette.doneHead
        case .amber: Theme.Palette.warnText
        case .red: Theme.Palette.priorityUrgentBg
        }
    }

    /// Thin per-day load bar; fill is capacity ÷ an 8h day, capped at full.
    private func loadBar(minutes: Int, tier: WeekPlanner.LoadTier) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.hairline)
                Capsule().fill(loadColor(tier))
                    .frame(width: geo.size.width * min(1, CGFloat(minutes) / 480))
            }
        }
        .frame(height: 3)
    }

    /// The time axis: faint 30-min hairlines with meetings and timed tasks
    /// positioned by start, sized by duration, and split into side-by-side
    /// columns when they overlap in time (so concurrent items stay legible).
    private func axis(events: [CalendarEvent], tasks: [MustardTask]) -> some View {
        // Build minute spans (events first, then tasks) and lay out columns once.
        let eventSpans = events.enumerated().map { i, e in
            WeekPlanner.AxisSpan(
                id: "e\(i)",
                startMinute: WeekPlanner.minutesSinceDayStart(e.start, dayStartHour: axisStartHour, calendar: cal),
                endMinute: WeekPlanner.minutesSinceDayStart(e.start, dayStartHour: axisStartHour, calendar: cal)
                    + durationMinutes(e))
        }
        let taskSpans = tasks.enumerated().map { i, t in
            WeekPlanner.AxisSpan(
                id: "t\(i)",
                startMinute: WeekPlanner.minutesSinceDayStart(t.scheduledAt ?? .now, dayStartHour: axisStartHour, calendar: cal),
                endMinute: WeekPlanner.minutesSinceDayStart(t.scheduledAt ?? .now, dayStartHour: axisStartHour, calendar: cal)
                    + t.estimateMinutes)
        }
        let placements = WeekPlanner.axisColumns(eventSpans + taskSpans)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Hour / half-hour gridlines.
                ForEach(0...((axisEndHour - axisStartHour) * 2), id: \.self) { half in
                    let onHour = half % 2 == 0
                    Rectangle()
                        .fill(Theme.Palette.hairline.opacity(onHour ? 1 : 0.4))
                        .frame(height: 1)
                        .offset(y: CGFloat(half) * (hourHeight / 2))
                }
                ForEach(Array(events.enumerated()), id: \.offset) { i, event in
                    let p = placements["e\(i)"] ?? .init(column: 0, columnCount: 1)
                    AxisMeetingBlock(event: event, height: blockHeight(minutes: durationMinutes(event)))
                        .frame(width: columnWidth(geo.size.width, p))
                        .offset(x: columnX(geo.size.width, p), y: yOffset(for: event.start))
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { i, task in
                    let p = placements["t\(i)"] ?? .init(column: 0, columnCount: 1)
                    AxisTaskBlock(task: task,
                                  perMinute: perMinute,
                                  height: blockHeight(minutes: task.estimateMinutes),
                                  onOpen: { selectedTask = task },
                                  onToggle: { toggle(task) })
                        .draggable(task.uid)
                        .contextMenu { menu(for: task) }
                        .frame(width: columnWidth(geo.size.width, p))
                        .offset(x: columnX(geo.size.width, p), y: yOffset(for: task.scheduledAt ?? Date()))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: axisHeight)
    }

    /// Gap between side-by-side overlapping blocks.
    private let columnGap: CGFloat = 3

    private func columnWidth(_ total: CGFloat, _ p: WeekPlanner.AxisPlacement) -> CGFloat {
        let slot = total / CGFloat(p.columnCount)
        return max(0, slot - (p.column < p.columnCount - 1 ? columnGap : 0))
    }

    private func columnX(_ total: CGFloat, _ p: WeekPlanner.AxisPlacement) -> CGFloat {
        (total / CGFloat(p.columnCount)) * CGFloat(p.column)
    }

    private func yOffset(for date: Date) -> CGFloat {
        let m = WeekPlanner.minutesSinceDayStart(date, dayStartHour: axisStartHour, calendar: cal)
        return max(0, CGFloat(m) * perMinute)
    }

    private func blockHeight(minutes: Int) -> CGFloat {
        max(18, CGFloat(minutes) * perMinute)
    }

    private func durationMinutes(_ event: CalendarEvent) -> Int {
        max(30, Int(event.end.timeIntervalSince(event.start) / 60))
    }

    // MARK: - Mutations

    @ViewBuilder private func menu(for task: MustardTask) -> some View {
        if task.owner == .me && task.delegation == nil && task.stage != .done {
            Button { agent.delegate(task) } label: {
                Label("Ask agent to do this", systemImage: "cpu")
            }
            Divider()
        }
        if task.stage == .done {
            Button("Reopen") { task.stage = .planned; task.completedAt = nil }
        } else {
            Button("Complete") { task.markDone() }
        }
        Button("Open detail") { selectedTask = task }
        Button("Unschedule") { task.scheduledAt = nil; task.isTimed = false }
        Divider()
        Button("Delete", role: .destructive) { context.delete(task) }
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

// MARK: - Chips & blocks

/// Rail chip: an unscheduled or overdue task.
struct WeekChip: View {
    let task: MustardTask
    var overdue = false
    var body: some View {
        HStack(spacing: 6) {
            Text(task.title).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            Spacer(minLength: 0)
            DelegationBadge(task: task)
            if overdue, let when = task.scheduledAt {
                Text(when.formatted(.dateTime.day().month()))
                    .font(.system(size: 9)).foregroundStyle(Theme.Palette.warning)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(overdue ? Theme.Palette.warning.opacity(0.5) : Theme.Palette.hairline))
    }
}

struct MeetingBlock: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text(event.title)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            if let join = event.joinURL, let url = URL(string: join) {
                Link("Join", destination: url)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Palette.hairline))
    }
}

/// A meeting positioned on the time axis, sized by its duration.
struct AxisMeetingBlock: View {
    let event: CalendarEvent
    let height: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary)
            Text(event.title)
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Palette.hairline))
    }
}

/// A timed task positioned on the axis, sized by `estimateMinutes`, with a
/// bottom resize handle that writes the snapped duration back to the estimate.
struct AxisTaskBlock: View {
    @Bindable var task: MustardTask
    let perMinute: CGFloat
    let height: CGFloat
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var dragStartEstimate: Int?

    private var tint: Color { task.owner == .agent ? Theme.Palette.agent : Theme.Palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button(action: onToggle) {
                    Image(systemName: task.stage == .done ? "checkmark.circle.fill" : "circle")
                        .font(Theme.Fonts.caption).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                if let when = task.scheduledAt {
                    Text(when.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
                }
                Spacer(minLength: 0)
            }
            Text(task.title)
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textPrimary)
                .strikethrough(task.stage == .done, color: Theme.Palette.textTertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.25)))
        .overlay(alignment: .bottom) { resizeHandle }
        .onTapGesture(perform: onOpen)
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(tint.opacity(0.4))
            .frame(width: 24, height: 4)
            .padding(.bottom, 2)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartEstimate == nil { dragStartEstimate = task.estimateMinutes }
                        let delta = Int(value.translation.height / perMinute)
                        task.estimateMinutes = WeekPlanner.snapDuration((dragStartEstimate ?? 30) + delta)
                    }
                    .onEnded { _ in dragStartEstimate = nil }
            )
    }
}

/// A task in the list below the axis (untimed, or timed outside the window).
struct WeekBlock: View {
    @Bindable var task: MustardTask
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var tint: Color { task.owner == .agent ? Theme.Palette.agent : Theme.Palette.accent }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: task.stage == .done ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Fonts.caption).foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                if task.isTimed, let when = task.scheduledAt {
                    Text(when.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                }
                Text(task.title)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .strikethrough(task.stage == .done, color: Theme.Palette.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: onOpen)
    }
}
