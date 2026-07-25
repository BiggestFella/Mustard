import SwiftUI
import SwiftData

/// The four-step "Plan your day" wizard (spec 2026-07-06, BAK-50):
/// 1 Rollover · 2 Agent standup · 3 Pick today · 4 Focus. A calm sheet over Today
/// that renders `RitualPlanner` / `RecommendationQueue` content and dispatches to
/// existing engines (task `scheduledAt`/`focusOnDay` mutations, `AgentService`).
/// No claude runs — the whole ritual is local and instant. View-only: all decisions
/// live in Logic/. Theme tokens throughout (this is a YOU surface, so accent-family,
/// not the dark notch).
public struct MorningRitualView: View {
    /// The day captured at sheet open — content keys off this so a midnight flip
    /// while the sheet is open is a cosmetic-only edge (spec "Failure/edge behavior").
    let day: Date
    /// Host stamps `lastPlannedDay` + dismisses the sheet.
    let onFinish: () -> Void
    /// Closes the sheet and navigates to the Agent tab.
    let onOpenConsole: () -> Void

    @Environment(AgentService.self) private var agent
    @Environment(\.modelContext) private var context
    @Query private var tasks: [MustardTask]
    @Query private var recs: [Recommendation]

    @State private var step = 0                        // 0...3

    /// Per-row rollover choice, keyed by task `uid`. Once a row is decided we render
    /// ONLY its chosen-state label (not the action buttons) — this is what prevents a
    /// second tap firing `pushToTomorrow` on an already-cleared `scheduledAt` (review
    /// rule 2). "Today" is the implicit default (no entry ⇒ show all three actions).
    enum RolloverChoice { case today, tomorrow, inbox }
    @State private var rolloverChoice: [String: RolloverChoice] = [:]

    /// Set true when a 4th star is refused, so the calm cap hint shows. Cleared on any
    /// successful toggle so it doesn't linger after the user frees a slot.
    @State private var focusCapHit = false

    public init(day: Date, onFinish: @escaping () -> Void, onOpenConsole: @escaping () -> Void) {
        self.day = day
        self.onFinish = onFinish
        self.onOpenConsole = onOpenConsole
    }

    private static let stepNames = ["Rollover", "Agent", "Pick", "Focus"]
    private var lastStep: Int { Self.stepNames.count - 1 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progressRail
                .padding(.top, 16)
                .padding(.bottom, 4)
            Divider().overlay(Theme.Palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.Palette.hairline)
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .background(Theme.Palette.bg)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Plan your day")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text("Step \(step + 1) of \(Self.stepNames.count)")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: Progress rail

    private var progressRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<Self.stepNames.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.Palette.accent : Theme.Palette.hairline)
                        .frame(height: 4)
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<Self.stepNames.count, id: \.self) { i in
                    Text("\(i + 1) \(Self.stepNames[i])")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(stepNameColor(i))
                    if i < Self.stepNames.count - 1 {
                        Text("·")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func stepNameColor(_ i: Int) -> Color {
        if i == step { return Theme.Palette.accent }
        if i < step { return Theme.Palette.textSecondary }
        return Theme.Palette.textTertiary
    }

    // MARK: Step content

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0: rolloverStep
        case 1: agentStep
        case 2: pickStep
        default: focusStep
        }
    }

    // MARK: Step 0 — Rollover

    @ViewBuilder private var rolloverStep: some View {
        let rolled = RitualPlanner.rollover(tasks, day: day)
        if rolled.isEmpty {
            emptyLine("Nothing rolled over — clean slate.")
        } else {
            HStack {
                Text("Carried onto today")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button("Keep all today →") { advance() }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.accent)
            }
            ForEach(rolled) { task in
                rolloverRow(task)
                Divider().overlay(Theme.Palette.hairline)
            }
        }
    }

    @ViewBuilder private func rolloverRow(_ task: MustardTask) -> some View {
        HStack(spacing: 10) {
            Text(task.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 12)
            if let choice = rolloverChoice[task.uid] {
                // Chosen state — render ONLY the label, no re-tappable actions
                // (review rule 2: never re-fire a mutation on a cleared field).
                Text(choiceLabel(choice))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                HStack(spacing: 6) {
                    pill("Today", tint: Theme.Palette.textSecondary) {
                        rolloverChoice[task.uid] = .today          // no-op mutation
                    }
                    pill("Tomorrow", tint: Theme.Palette.accent) {
                        RitualPlanner.pushToTomorrow(task)
                        rolloverChoice[task.uid] = .tomorrow
                    }
                    pill("Inbox", tint: Theme.Palette.textSecondary) {
                        RitualPlanner.sendToInbox(task)
                        rolloverChoice[task.uid] = .inbox
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func choiceLabel(_ choice: RolloverChoice) -> String {
        switch choice {
        case .today: return "→ Today"
        case .tomorrow: return "→ Tomorrow"
        case .inbox: return "→ Inbox"
        }
    }

    // MARK: Step 1 — Agent standup

    @ViewBuilder private var agentStep: some View {
        let pending = RecommendationQueue.pending(recs, now: .now)
        let outputs = AgentInbox.outputCount(tasks)
        if pending.isEmpty && outputs == 0 {
            emptyLine("Nothing from the agent overnight.")
        } else {
            ForEach(pending) { rec in
                standupRow(rec)
                Divider().overlay(Theme.Palette.hairline)
            }
            if outputs > 0 {
                Button {
                    onOpenConsole()
                } label: {
                    Text("\(outputs) output\(outputs == 1 ? "" : "s") waiting review — Open in console →")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func standupRow(_ rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sourceChip(rec)
                Text(String(format: "%.2f", rec.confidence))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.confidenceColor(rec.confidence))
                Spacer()
            }
            Text(rec.title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                pill("Approve", tint: Theme.Palette.accent) {
                    Task { await agent.decide(rec, .approved) }
                }
                pill("I'll do it", tint: Theme.Palette.textSecondary) {
                    Task { await agent.decide(rec, .selfExecute) }
                }
                pill("Snooze", tint: Theme.Palette.textSecondary) {
                    agent.snooze(rec, until: SnoozeTargets.nextNineAM(after: .now))
                }
                pill("Reject", tint: Theme.Palette.textSecondary) {
                    Task { await agent.decide(rec, .denied) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Compact source chip, echoing the console's `ProvenancePill` treatment.
    @ViewBuilder private func sourceChip(_ rec: Recommendation) -> some View {
        let badge = SourceBadge.badge(forRaw: rec.source)
        if badge.isQuiet {
            Text(badge.label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
        } else {
            HStack(spacing: 4) {
                SourceLogo(source: badge.id, size: 13)
                Text(badge.label)
            }
            .font(Theme.Fonts.caption.weight(.medium))
            .foregroundStyle(Color(hex: badge.fgHex))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color(hex: badge.bgHex), in: Capsule())
        }
    }

    // MARK: Step 2 — Pick today

    @ViewBuilder private var pickStep: some View {
        if let capacity = RitualPlanner.capacityLine(tasks, day: day) {
            Text(capacity)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        let planned = RitualPlanner.plannedToday(tasks, day: day)
        if !planned.isEmpty {
            Text("PLANNED TODAY")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
            ForEach(planned) { task in
                pickRow(task, planned: true)
                Divider().overlay(Theme.Palette.hairline)
            }
        }
        let candidates = RitualPlanner.pickCandidates(tasks)
        Text("INBOX")
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.top, planned.isEmpty ? 0 : 8)
        if candidates.isEmpty {
            emptyLine("Inbox is empty.")
        } else {
            ForEach(candidates) { task in
                pickRow(task, planned: false)
                Divider().overlay(Theme.Palette.hairline)
            }
        }
    }

    @ViewBuilder private func pickRow(_ task: MustardTask, planned: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if planned {
                    RitualPlanner.sendToInbox(task)
                } else {
                    RitualPlanner.planToday(task, day: day)
                }
            } label: {
                Image(systemName: planned ? "minus.circle" : "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(planned ? Theme.Palette.textTertiary : Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            Text(task.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Step 3 — Focus

    @ViewBuilder private var focusStep: some View {
        let candidates = RitualPlanner.focusCandidates(tasks, day: day)
        if candidates.isEmpty {
            emptyLine("Nothing planned to focus on yet.")
        } else {
            Text("Star up to \(RitualPlanner.focusLimit) tasks as today's focus")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
            ForEach(candidates) { task in
                focusRow(task)
                Divider().overlay(Theme.Palette.hairline)
            }
            if focusCapHit {
                Text("Three focus tasks is plenty.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.warnText)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func focusRow(_ task: MustardTask) -> some View {
        let isStarred = task.focusOnDay.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
        HStack(spacing: 10) {
            Button {
                // Review rule 1: pass the FULL `tasks` @Query array as `in all:` so the
                // 3-star cap counts against everything, not a filtered subset.
                let ok = RitualPlanner.toggleFocus(task, in: tasks, day: day)
                if ok { focusCapHit = false } else { focusCapHit = true }
            } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(isStarred ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            Text(task.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Button(step == lastStep ? "Skip" : "Skip step") {
                if step == lastStep { onFinish() } else { advance() }
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Palette.textTertiary)

            Button {
                if step == lastStep { onFinish() } else { advance() }
            } label: {
                Text(step == lastStep ? "Start the day" : "Continue")
                    .font(Theme.Fonts.meta.weight(.medium))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.accent.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func advance() {
        focusCapHit = false
        if step < lastStep { step += 1 }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.vertical, 8)
    }

    /// Small tappable capsule action used across the steps.
    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(tint)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
