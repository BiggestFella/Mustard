import SwiftUI
import SwiftData

public struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var allTasks: [MustardTask]
    @Query private var recommendations: [Recommendation]
    @State private var selectedTask: MustardTask?
    @State private var nudgeDismissed = false
    private let today = Date.now
    /// Navigate to the Agent console (the header "✦ Plan with agent" entry).
    private let onPlan: () -> Void

    // Morning-ritual entry state. The two Doubles are epoch seconds (0 == never);
    // RitualPrompt works in Date? so we bridge in `shouldOffer` below.
    @AppStorage(RitualPrompt.lastPlannedKey) private var lastPlanned: Double = 0
    @AppStorage(RitualPrompt.dismissedKey) private var ritualDismissed: Double = 0
    @State private var showRitual = false
    // ⌘K → open-ritual channel. The command bar can't reach Today's local
    // `showRitual` state, so it flips this AppStorage flag (the app's existing
    // lightweight cross-view channel); we consume it in onAppear/onChange.
    @AppStorage(RitualPrompt.openRequestedKey) private var ritualOpenRequested = false

    public init(onPlan: @escaping () -> Void = {}) { self.onPlan = onPlan }

    /// Whether to show the "Plan your day" banner (and offer the ritual at all).
    private var shouldOffer: Bool {
        RitualPrompt.shouldOffer(
            lastPlannedDay: lastPlanned > 0 ? Date(timeIntervalSince1970: lastPlanned) : nil,
            dismissedDay: ritualDismissed > 0 ? Date(timeIntervalSince1970: ritualDismissed) : nil,
            now: .now)
    }

    /// Today's focus-starred open tasks — pinned above the timeline.
    private var focusTasks: [MustardTask] { RitualPlanner.focused(allTasks, day: today) }

    private var progress: (done: Int, total: Int) { DayPlanner.dayProgress(allTasks, day: today) }
    private var nudgeCount: Int { AgentInbox.waitingCount(recommendations: recommendations, tasks: allTasks) }

    /// The forward-flowing spine: today (always shown) plus upcoming days that carry
    /// items. Events are empty until Google OAuth is wired; the rail then lights up with
    /// no further view work. FOCUS-pinned tasks are excluded from today (BAK-247).
    private var spine: [SpineDay] {
        TimelineSpine.build(tasks: allTasks, events: [], reference: today)
    }
    /// Today's item count is used for the empty-state guard and the summary line.
    private var todayItems: [AgendaItem] { spine.first(where: { $0.label == .today })?.items ?? [] }
    private var unscheduled: [MustardTask] { DayPlanner.unscheduled(allTasks) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                summaryLine
                progressBar
                ritualBanner
                agentNudge
                focusSection
                TimelineSpineView(
                    days: spine,
                    now: today,
                    onToggleDone: { toggle($0) },
                    onOpen: { selectedTask = $0 }
                )
                if todayItems.isEmpty && focusTasks.isEmpty {
                    // Warm empty state (Craft pass Phase 1) — points at the capture
                    // field directly below it. Guards on FOCUS too so a day whose only
                    // tasks are pinned above doesn't read as "nothing scheduled" (BAK-247).
                    VStack(spacing: 8) {
                        Image(systemName: "sun.max")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text("Nothing scheduled yet")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text("Capture a task below to start the day")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                QuickCaptureField(scheduleOnto: today)

                if !unscheduled.isEmpty {
                    Text("INBOX")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.top, 24)
                        .padding(.bottom, 4)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(unscheduled) { task in
                            TimelineRow(task: task, onToggleDone: { toggle(task) }, onOpen: { selectedTask = task })
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.bg)
        .onAppear {
            DayPlanner.carryForward(allTasks, to: today)
            consumeRitualRequest()
        }
        .onChange(of: ritualOpenRequested) { consumeRitualRequest() }
        .taskDetailDrawer(item: $selectedTask)
        .sheet(isPresented: $showRitual) {
            MorningRitualView(
                day: today,
                onFinish: { lastPlanned = Date.now.timeIntervalSince1970; showRitual = false },
                onOpenConsole: { showRitual = false; onPlan() })
        }
    }

    /// Honour a ⌘K "Plan my day" request routed through AppStorage, then clear it.
    private func consumeRitualRequest() {
        if ritualOpenRequested {
            showRitual = true
            ritualOpenRequested = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Today")
                .font(Theme.Fonts.docH1)   // editorial weight (Craft pass Phase 1); same 22pt
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(today.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Button(action: onPlan) {
                Text("✦ Plan with agent")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.agentText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Theme.Palette.agentTintLight, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Open the Agent console to plan your day.")
        }
        .padding(.bottom, 12)
    }

    /// "Plan your day" banner — a YOU action (not the agent), so accent-family
    /// styling: plain surface + hairline, sunrise glyph in accent. Shown until the
    /// day is planned or the offer is dismissed (both reset at midnight).
    @ViewBuilder private var ritualBanner: some View {
        if shouldOffer {
            let rolled = RitualPlanner.rollover(allTasks, day: today).count
            let recs = AgentInbox.pendingRecCount(recommendations)
            HStack(spacing: 10) {
                Image(systemName: "sunrise")
                    .font(Theme.Fonts.meta.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan your day")
                        .font(Theme.Fonts.meta.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(ritualSubtitle(rolled: rolled, recs: recs))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    ritualDismissed = Date.now.timeIntervalSince1970
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Fonts.caption.weight(.medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss for today")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { showRitual = true }
            .padding(.bottom, 16)
        }
    }

    /// Subtitle assembled from counts; omit zero parts, both zero → generic line.
    private func ritualSubtitle(rolled: Int, recs: Int) -> String {
        var parts: [String] = []
        if rolled > 0 { parts.append("\(rolled) rolled over") }
        if recs > 0 { parts.append("\(recs) from the agent") }
        return parts.isEmpty ? "Set up today in under a minute" : parts.joined(separator: " · ")
    }

    /// FOCUS pins — today's starred tasks, above the chronological spine. These are
    /// excluded from the spine's TODAY section (`TimelineSpine.build` filters out
    /// `focusOnDay` UIDs, BAK-247) so a pinned task shows exactly once, here, rather
    /// than duplicated on the rail below.
    @ViewBuilder private var focusSection: some View {
        let focus = focusTasks
        if !focus.isEmpty {
            Text("FOCUS")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.top, 4)
                .padding(.bottom, 4)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(focus) { task in
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.accent)
                        TimelineRow(task: task, onToggleDone: { toggle(task) }, onOpen: { selectedTask = task })
                    }
                    Divider().overlay(Theme.Palette.hairline)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// Dismissible nudge shown when the agent has items waiting (recs + review).
    /// Auto-hides when the queue empties; tap opens the Agent console.
    @ViewBuilder private var agentNudge: some View {
        let n = nudgeCount
        if n > 0 && !nudgeDismissed {
            HStack(spacing: 10) {
                Text("✦")
                    .font(Theme.Fonts.meta.weight(.semibold))
                    .foregroundStyle(Theme.Palette.agentText)
                    .frame(width: 24, height: 24)
                    .background(Theme.Palette.agentTintLight, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent has \(n) thing\(n == 1 ? "" : "s") for you")
                        .font(Theme.Fonts.meta.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Tap to review in the Agent console")
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    nudgeDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Fonts.caption.weight(.medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.Palette.agentTintFaint, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.agentTintMid, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture(perform: onPlan)
            .padding(.bottom, 16)
        }
    }

    /// Calm one-liner under the header: "N tasks · agent on M" (events appended once the
    /// calendar source is wired). Zero parts are omitted; nothing shows on an empty day.
    @ViewBuilder private var summaryLine: some View {
        if !summaryParts.isEmpty {
            Text(summaryParts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.bottom, 10)
        }
    }

    /// Builds the summaryLine parts ("N tasks", "agent on M") from today's items. Pulled
    /// out of the @ViewBuilder body above: mutating statements guarded by a bare `if`
    /// are transformed by the ViewBuilder DSL and must themselves conform to `View`,
    /// which a `[String].append` call does not — so the array-building lives here instead.
    private var summaryParts: [String] {
        let items = todayItems
        let taskCount = items.filter { if case .task = $0.kind { return true }; return false }.count
        let agentCount = items.filter {
            if case let .task(t) = $0.kind { return t.owner == .agent }; return false
        }.count
        var parts: [String] = []
        if taskCount > 0 { parts.append("\(taskCount) task\(taskCount == 1 ? "" : "s")") }
        if agentCount > 0 { parts.append("agent on \(agentCount)") }
        return parts
    }

    /// Thin day-progress bar — "N of M done" over today's scheduled tasks.
    @ViewBuilder private var progressBar: some View {
        let p = progress
        if p.total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Palette.hairline)
                        Capsule().fill(Theme.Palette.done)
                            .frame(width: geo.size.width * CGFloat(p.done) / CGFloat(p.total))
                    }
                }
                .frame(height: 4)
                Text("\(p.done) of \(p.total) done")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.bottom, 16)
        }
    }

    private func toggle(_ task: MustardTask) {
        guard CodeHeroesDecisionPresentation.allowsLocalCompletion(for: task) else { return }
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            TaskCompletion.complete(task, in: context)
        }
    }
}

#Preview {
    TodayView()
        .modelContainer(PreviewData.container)
}
