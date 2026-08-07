import SwiftUI
import SwiftData

/// Mobile Week (BAK-116): a horizontal Mon–Sun day-strip with per-day capacity load,
/// a single selected-day plan (meetings + tasks grouped by time-of-day), and a rail of
/// unscheduled + overdue tasks you TAP to schedule onto the selected day. No drag and no
/// ✦ Balance on mobile — those are desktop-only. The shared area filter (MobileFilters,
/// also driving Board) scopes the strip, rail, and day list; owner isn't surfaced here
/// because the rail is my-open-work by design (WeekPlanner.unscheduled/overdue).
struct MobileWeekView: View {
    @Environment(\.modelContext) private var context
    @Query private var allTasks: [MustardTask]
    @Query private var events: [CalendarEvent]
    @Bindable var filters: MobileFilters

    @State private var weekOffset = 0
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var selected: MustardTask?
    @State private var scheduledToast: String?

    private let cal = Calendar.current

    // Area-scoped task set feeding every WeekPlanner call, so strip/rail/day agree.
    private var scoped: [MustardTask] { allTasks.filter { PersonalBoard.matchesArea($0, filters.area) } }
    private var days: [Date] { WeekPlanner.days(weekOffset: weekOffset) }
    private var unscheduled: [MustardTask] { WeekPlanner.unscheduled(scoped) }
    private var overdue: [MustardTask] { WeekPlanner.overdue(scoped) }
    private var dayTasks: [MustardTask] { WeekPlanner.tasks(scoped, on: selectedDay) }
    private var dayEvents: [CalendarEvent] { events.filter { cal.isDate($0.start, inSameDayAs: selectedDay) } }

    private var accent: Color { Theme.Palette.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MobileAreaChips(filters: filters)
                    dayStrip
                    dayHeader
                    dayPlan
                    rail
                }
                .padding()
            }
            .navigationTitle("Week")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { weekNav } }
            .sheet(item: $selected) { MobileTaskSheet(task: $0) }
            .overlay(alignment: .bottom) { toast }
            .animation(Theme.Motion.easeOut(), value: scheduledToast)
            .task(id: scheduledToast) {
                guard scheduledToast != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                scheduledToast = nil
            }
        }
    }

    // MARK: Week navigation

    private var weekNav: some View {
        HStack(spacing: 14) {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
            Button("Today") { weekOffset = 0; selectedDay = cal.startOfDay(for: .now) }
                .font(.caption.weight(.medium))
                .foregroundStyle(weekOffset == 0 ? Color.secondary : accent)
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
        }
        .font(.subheadline)
    }

    // MARK: Day strip

    private var dayStrip: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in dayCell(day) }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        let minutes = WeekPlanner.capacityMinutes(scoped, on: day, calendar: cal)
        let tier = WeekPlanner.loadTier(minutes: minutes)
        return Button {
            selectedDay = cal.startOfDay(for: day)
        } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .white : (isToday ? accent : .secondary))
                Text(day.formatted(.dateTime.day()))
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                Circle()
                    .fill(minutes == 0 ? Theme.Palette.loadEmptyDot : loadColor(tier))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? AnyShapeStyle(Theme.Palette.textPrimary) : AnyShapeStyle(Theme.Palette.titleBar),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isToday && !isSelected ? accent.opacity(0.4) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func loadColor(_ tier: WeekPlanner.LoadTier) -> Color {
        switch tier {
        case .green: Theme.Palette.done
        case .amber: Theme.Palette.warnText
        case .red: Theme.Palette.priorityUrgentBg
        }
    }

    // MARK: Selected-day header (capacity)

    private var dayHeader: some View {
        let minutes = WeekPlanner.capacityMinutes(scoped, on: selectedDay, calendar: cal)
        let tier = WeekPlanner.loadTier(minutes: minutes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).day().month()))
                    .font(.headline)
                Spacer()
                Text(WeekPlanner.capacityLabel(minutes: minutes) + " planned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(minutes == 0 ? .secondary : loadColor(tier))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.hairline)
                    Capsule().fill(loadColor(tier))
                        .frame(width: geo.size.width * min(1, CGFloat(minutes) / 480))
                }
            }.frame(height: 4)
        }
    }

    // MARK: Selected-day plan

    @ViewBuilder private var dayPlan: some View {
        if dayEvents.isEmpty && dayTasks.isEmpty {
            Text("Nothing scheduled — tap a task below to plan it here.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(dayEvents) { meetingRow($0) }
                ForEach(WeekPlanner.groupByTimeOfDay(dayTasks, calendar: cal), id: \.0) { group in
                    Text(group.0.label.uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(group.1) { dayCard($0) }
                }
            }
        }
    }

    private func meetingRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary)
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(event.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.Palette.statusMutedBg, in: RoundedRectangle(cornerRadius: 10))
    }

    /// A scheduled task on the selected day. Tap opens the sheet; the completion
    /// toggle and context menu stay independently tappable (card is not a Button).
    private func dayCard(_ task: MustardTask) -> some View {
        let done = task.stage == .done
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if done { task.stage = .planned; task.completedAt = nil }
                else { TaskCompletion.complete(task, in: context) }
            } label: {
                Image(systemName: done ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(done ? Theme.Palette.done
                                     : (task.owner == .agent ? Theme.Palette.agent : .secondary))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                HStack(spacing: 8) {
                    if task.isTimed, let when = task.scheduledAt {
                        Text(when.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(task.owner == .agent ? Theme.Palette.agentText : accent)
                    }
                    if task.owner == .agent {
                        Text("✦ Agent").font(.caption2).foregroundStyle(Theme.Palette.agentText)
                    }
                    if let area = task.list?.area {
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: area.colorHex)).frame(width: 6, height: 6)
                            Text(area.name)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(task.estimateMinutes)m").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { selected = task }
        .contextMenu {
            Button("Open detail") { selected = task }
            Button("Unschedule") { task.scheduledAt = nil; task.isTimed = false }
            if done { Button("Reopen") { task.stage = .planned; task.completedAt = nil } }
            else { Button("Complete") { TaskCompletion.complete(task, in: context) } }
        }
    }

    // MARK: Rail (tap to schedule onto the selected day)

    @ViewBuilder private var rail: some View {
        let dayLabel = selectedDay.formatted(.dateTime.weekday(.abbreviated))
        if !overdue.isEmpty {
            railSection("OVERDUE", overdue, dayLabel: dayLabel, accent: Theme.Palette.priorityUrgentBg)
        }
        railSection("UNSCHEDULED", unscheduled, dayLabel: dayLabel, accent: nil)
    }

    private func railSection(_ title: String, _ tasks: [MustardTask], dayLabel: String, accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold))
                .foregroundStyle(accent ?? Color.secondary)
                .padding(.top, 4)
            if tasks.isEmpty {
                Text(title == "UNSCHEDULED" ? "All scheduled" : "")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { railCard($0, dayLabel: dayLabel, overdue: accent != nil) }
            }
        }
    }

    /// Rail task: tapping the card schedules it onto the selected day (drag's mobile
    /// stand-in). Long-press → detail / schedule. Not a Button so the trailing "＋ day"
    /// pill reads as the primary hint without nesting Button-in-Button.
    private func railCard(_ task: MustardTask, dayLabel: String, overdue: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.subheadline).lineLimit(2)
                HStack(spacing: 8) {
                    if let area = task.list?.area {
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: area.colorHex)).frame(width: 6, height: 6)
                            Text(area.name)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    if overdue, let when = task.scheduledAt {
                        Text("was \(when.formatted(.dateTime.day().month()))")
                            .font(.caption2).foregroundStyle(Theme.Palette.priorityUrgentBg)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("＋ \(dayLabel)")
                .font(.caption2.weight(.semibold)).foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(accent.opacity(0.12), in: Capsule())
        }
        .padding(11)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(overdue ? Theme.Palette.priorityUrgentBg.opacity(0.4) : Theme.Palette.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { schedule(task) }
        .contextMenu {
            Button("Schedule onto \(dayLabel)") { schedule(task) }
            Button("Open detail") { selected = task }
        }
    }

    private func schedule(_ task: MustardTask) {
        task.scheduledAt = WeekPlanner.scheduleDate(on: selectedDay, keepingTimeFrom: task.scheduledAt, calendar: cal)
        PersonalBoard.normalizePlacement(task)
        scheduledToast = "Scheduled onto \(selectedDay.formatted(.dateTime.weekday(.abbreviated).day().month()))"
    }

    private var toast: some View {
        Group {
            if let scheduledToast {
                Text(scheduledToast)
                    .font(Theme.Fonts.meta.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.Palette.textPrimary, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
