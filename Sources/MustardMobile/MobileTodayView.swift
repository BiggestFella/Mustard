import SwiftUI
import SwiftData

/// Mobile Today (BAK-113): day-progress bar, agent nudge, FOCUS pins, timeline
/// with gate-status pills (mobile-only), and the inbox — reusing the tested
/// DayPlanner / RitualPlanner / AgentInbox logic. FOCUS-starred tasks render
/// once in the FOCUS band (BAK-247), matching desktop Today.
struct MobileTodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var allTasks: [MustardTask]
    @Query private var recommendations: [Recommendation]
    @State private var selected: MustardTask?
    /// Tap the nudge → jump to the Triage (Agent) tab.
    let onOpenTriage: () -> Void

    private let today = Date.now
    /// Today's focus-starred tasks — pinned above the timeline (desktop parity).
    private var focusTasks: [MustardTask] { RitualPlanner.focused(allTasks, day: today) }
    /// Chronological today list minus FOCUS pins so a starred task shows once.
    private var scheduled: [MustardTask] { RitualPlanner.timeline(allTasks, day: today) }
    private var inbox: [MustardTask] { DayPlanner.unscheduled(allTasks) }
    private var progress: (done: Int, total: Int) { DayPlanner.dayProgress(allTasks, day: today) }
    private var nudge: Int { AgentInbox.waitingCount(recommendations: recommendations, tasks: allTasks) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if progress.total > 0 { progressBar }
                    if nudge > 0 { nudgeCard }
                    focusSection

                    if scheduled.isEmpty && inbox.isEmpty && focusTasks.isEmpty {
                        // Guard on FOCUS too so a day whose only tasks are pinned
                        // above doesn't read as "nothing scheduled" (BAK-247).
                        Text("Nothing scheduled yet")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(scheduled) { row($0) }

                    if !inbox.isEmpty {
                        Text("INBOX").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary).padding(.top, 10)
                        ForEach(inbox) { row($0) }
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .sheet(item: $selected) { MobileTaskSheet(task: $0) }
        }
    }

    /// FOCUS pins — today's starred tasks, above the chronological list. These
    /// are excluded from `scheduled` via `RitualPlanner.timeline` (BAK-247).
    @ViewBuilder private var focusSection: some View {
        let focus = focusTasks
        if !focus.isEmpty {
            Text("FOCUS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(focus) { row($0, pinned: true) }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.hairline)
                    Capsule().fill(Theme.Palette.done)
                        .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                }
            }.frame(height: 4)
            Text("\(progress.done) of \(progress.total) done")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nudgeCard: some View {
        Button(action: onOpenTriage) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.Palette.agentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent has \(nudge) thing\(nudge == 1 ? "" : "s") for you")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text("Tap to review in Triage").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Theme.Palette.agentTintFaint, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func row(_ task: MustardTask, pinned: Bool = false) -> some View {
        let done = task.stage == .done
        return Button { selected = task } label: {
            HStack(alignment: .top, spacing: 10) {
                if pinned {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.top, 4)
                }
                Button {
                    if done { task.stage = .planned; task.completedAt = nil }
                    else { TaskCompletion.complete(task, in: context) }
                } label: {
                    Image(systemName: done ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(done ? Theme.Palette.done
                                         : (task.owner == .agent ? Theme.Palette.agent : .secondary))
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        PriorityFlag(priority: task.priority)
                        Text(task.title)
                            .font(.system(size: 15.5, weight: done ? .regular : .semibold))
                            .strikethrough(done)
                            .foregroundStyle(done ? .secondary : .primary)
                    }
                    // Same condensed detail-card chip vocabulary as the desktop row
                    // (BAK-245) — blocked · time · due · estimate · area · agent · subtasks.
                    if TaskChipRow.hasChips(task) {
                        TaskChipRow(task: task)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
}
