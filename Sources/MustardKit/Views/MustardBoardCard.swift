import SwiftUI
import SwiftData

/// A single board task card (BAK-79). Owner-segmented design — see the design
/// handoff "Component: Task Card". Presentational: it reads a `MustardTask` and
/// dispatches owner toggles to `PersonalBoard`/`AgentService`. Colours come from
/// `Theme` (the canonical token set — BAK-98); sizes are from the handoff.
public struct MustardBoardCard: View {
    @Environment(AgentService.self) private var agent
    @Environment(AgentTaskCoordinator.self) private var taskAgent
    @Environment(\.modelContext) private var context
    @State private var hovering = false
    let task: MustardTask
    let showConfidence: Bool

    public init(task: MustardTask, showConfidence: Bool) {
        self.task = task
        self.showConfidence = showConfidence
    }

    private var stage: TaskStage { task.stage }
    private var isDone: Bool { stage == .done }
    private var isAgent: Bool { task.owner == .agent }
    private var isBlocked: Bool { stage == .blocked || task.isBlocked }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            title
            metaRow
            tagsRow
            confidenceRow
            statusPill
            blockedRow
            gateActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        // Accent border before .elevation so its clip rounds the border with the card.
        .overlay(alignment: .leading) { accentBorder }
        .elevation(hovering ? .float : .card, cornerRadius: 9)
        .offset(y: hovering ? -1 : 0)   // grabbable hover lift, no layout shift
        .opacity(isDone ? 0.66 : 1)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.settle, value: hovering)
    }

    // MARK: Left accent border (2.5px)

    @ViewBuilder private var accentBorder: some View {
        if isBlocked {
            Theme.Palette.warning.frame(width: 2.5)
        } else if isAgent {
            Theme.Palette.agent.frame(width: 2.5)
        }
    }

    // MARK: Top row — priority flag · owner toggle · ✦ Proposed · gated padlock

    @ViewBuilder private var topRow: some View {
        if !isDone {
            HStack(spacing: 6) {
                PriorityFlag(priority: task.priority)   // shared with TimelineRow (BAK-245)
                if hovering { ownerToggle }   // hover-revealed (handoff); agent shown via the left accent
                Spacer(minLength: 0)
                if let capture = task.captureState, capture != .cleaned {
                    capturePill(capture)
                }
                if task.isProposed { proposedPill }
                if task.isGated {
                    Image(systemName: "lock")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .help("Gated action — always reviewed by you")
                }
            }
            .frame(minHeight: 18)
            .padding(.bottom, 7)
        }
    }

    // MARK: 🎙 Voice-capture pill (F25) — raw = cleanup pending, failed = gave up

    private func capturePill(_ state: CaptureState) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill").font(.system(size: 8))
            Text(state == .raw ? "Raw" : "Cleanup failed")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(state == .raw ? Theme.Palette.textSecondary : Theme.Palette.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Theme.Palette.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.Palette.divider, lineWidth: 0.5))
        .help(state == .raw
              ? "Voice capture — the agent will tidy the title and details shortly"
              : "Voice cleanup gave up — the raw transcript is kept as the title")
    }

    // MARK: ✦ Proposed pill (agent-surfaced inbox task)

    private var proposedPill: some View {
        Text("✦ Proposed")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.agentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Theme.Palette.agentTintLight, in: Capsule())
    }

    private var ownerToggle: some View {
        HStack(spacing: 0) {
            ownerTab(label: "You", active: !isAgent) {
                // Agent-owned work is taken back through the coordinator so the run is
                // cancelled and the local slot released; genuinely local tasks just reassign.
                if task.owner == .agent {
                    taskAgent.takeBack(task)
                } else {
                    PersonalBoard.reassign(task, to: .me)
                }
            }
            ownerTab(label: "✦", active: isAgent) {
                agent.delegate(task)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Palette.divider, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func ownerTab(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        let isAgentTab = label == "✦"
        Text(label)
            .font(.system(size: 10, weight: active ? .semibold : .regular))
            .foregroundStyle(
                active ? (isAgentTab ? Color.white : Theme.Palette.onSurface)
                       : Theme.Palette.ownerTabInactive
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                active ? (isAgentTab ? Theme.Palette.agent : Theme.Palette.chipActive)
                       : Color.clear
            )
            .contentShape(Rectangle())
            // Tapping the already-active tab is inert (defense in depth): re-delegation
            // and take-back are only meaningful when switching away from the current owner.
            .onTapGesture { if !active { action() } }
    }

    // MARK: Title

    private var title: some View {
        Text(task.title)
            .font(.system(size: 13.5))
            .lineSpacing(13.5 * 0.35)
            .foregroundStyle(isDone ? Theme.Palette.textMuted : Theme.Palette.textPrimary)
            .strikethrough(isDone, color: Theme.Palette.strikethrough)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Meta row — area · source · due

    @ViewBuilder private var metaRow: some View {
        let area = task.list?.area
        let badge = Theme.sourceBadge(for: task.source)
        let due = task.scheduledAt
        if area != nil || badge != nil || due != nil {
            FlowMeta {
                if let area {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: area.colorHex))
                            .frame(width: 7, height: 7)
                        Text(area.name)
                    }
                }
                if let badge {
                    HStack(spacing: 4) {
                        Text(badge.icon)
                        Text(badge.label)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(badge.fg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(badge.bg, in: Capsule())
                }
                if let due {
                    let overdue = due < .now && !isDone
                    Text("🗓 \(due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .foregroundStyle(overdue ? Theme.Palette.warning : Theme.Palette.accent)
                        .fontWeight(overdue ? .semibold : .regular)
                }
            }
            .font(Theme.Fonts.label)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.top, 8)
        }
    }

    // MARK: Tags (#tag, max 3)

    @ViewBuilder private var tagsRow: some View {
        let tags = Array(task.tags.prefix(3))
        if !tags.isEmpty {
            FlowMeta(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.Palette.statusMutedBg, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Confidence

    @ViewBuilder private var confidenceRow: some View {
        if showConfidence, stage == .needsApproval, let conf = task.confidence {
            let color = Theme.confidenceColor(conf)
            let filled = Int((conf * 5).rounded())
            HStack(spacing: 6) {
                Text(String(format: "%.2f", conf))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < filled ? color : Theme.Palette.confidenceUnfilled)
                            .frame(width: 11, height: 4)
                    }
                }
            }
            .padding(.top, 9)
        }
    }

    // MARK: Status pill

    @ViewBuilder private var statusPill: some View {
        if let s = statusInfo {
            Text(s.text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(s.fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(s.bg, in: Capsule())
                .padding(.top, 9)
        }
    }

    private var statusInfo: (text: String, fg: Color, bg: Color)? {
        switch stage {
        case .forAgent:
            return ("Waiting for agent to pick up", Theme.Palette.statusMutedText, Theme.Palette.statusMutedBg)
        case .needsApproval:
            return ("Your move · approve to run", Theme.Palette.agentText, Theme.Palette.agentTintLight)
        case .inProgress where isAgent:
            return ("Agent working…", Theme.Palette.agentText, Theme.Palette.agentTintLight)
        case .needsInput:
            // Amber only on the Needs You pill — the card keeps its agent-purple accent.
            return ("Your answer needed", Theme.Palette.warnText, Theme.Palette.warnTintSoft)
        case .queued:
            // A queued task with no action type can't be routed to the agent (BAK-89);
            // surface it in amber so it's visibly not-runnable until set in the detail sheet.
            if task.actionType == nil {
                return ("Needs an action type", Theme.Palette.warnText, Theme.Palette.warnTintSoft)
            }
            return ("Queued to run", Theme.Palette.statusMutedText, Theme.Palette.statusMutedBg)
        case .needsReview:
            return ("Review output", Theme.Palette.reviewText, Theme.Palette.reviewBg)
        default:
            return nil
        }
    }

    // MARK: Blocked reason

    @ViewBuilder private var blockedRow: some View {
        if isBlocked {
            let reason = task.blockedReason.trimmingCharacters(in: .whitespaces)
            Text("⚠ \(reason.isEmpty ? "Blocked" : reason)")
                .font(Theme.Fonts.label)
                .lineSpacing(11.5 * 0.35)
                .foregroundStyle(Theme.Palette.warnText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    // MARK: Inline gate actions (hover-revealed on the two gate stages)

    @ViewBuilder private var gateActions: some View {
        if hovering, stage == .needsApproval || stage == .needsReview {
            HStack(spacing: 6) {
                Button(action: approveGate) {
                    Text(primaryGateLabel)
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.Palette.agent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                Button(action: rejectGate) {
                    Text(secondaryGateLabel)
                        .font(Theme.Fonts.caption.weight(.medium))
                        .foregroundStyle(Theme.Palette.confidenceLow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
        }
    }

    /// "✓ Approve & run" (gated approval) / "✓ Approve" (non-gated) / "✓ Accept" (review).
    private var primaryGateLabel: String {
        if stage == .needsReview { return "✓ Accept" }
        return task.isGated ? "✓ Approve & run" : "✓ Approve"
    }

    private var secondaryGateLabel: String { stage == .needsReview ? "Discard" : "Deny" }

    private func approveGate() {
        guard let target = PersonalBoard.approveTarget(for: task) else { return }
        PersonalBoard.move(task, to: target)
    }

    /// Deny (needsApproval) / Discard (needsReview) both drop the task.
    private func rejectGate() { context.delete(task) }
}

// `FlowMeta` (the wrapping meta-row layout) moved to SharedUI/FlowMeta.swift so the iOS
// target can compile it too — it's shared by MustardBoardCard (desktop) and TaskChipRow.

#if DEBUG
#Preview {
    let ctx = PreviewData.container.mainContext
    let tasks = (try? ctx.fetch(FetchDescriptor<MustardTask>())) ?? []
    return ScrollView {
        VStack(spacing: 8) {
            ForEach(tasks) { MustardBoardCard(task: $0, showConfidence: true) }
        }
        .padding()
        .frame(width: 200)
    }
    .background(Theme.Palette.surface.opacity(0.4))
    .environment(AgentService(context: ctx))
    .environment(AgentTaskCoordinator(context: ctx))
}
#endif
