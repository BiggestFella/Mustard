#if os(macOS)
import SwiftUI
import SwiftData

/// Agent tab: what's waiting on Leon — pending recommendations and
/// attention-stage tasks — as read-only rows. The notch surfaces; the
/// Agent console acts (locked decision, 2026-07-02 redesign): no inline
/// Approve/Deny here, every row routes to the console.
struct NotchAgentTab: View {
    @Environment(NotchNavigation.self) private var nav
    @Query private var tasks: [MustardTask]
    @Query(sort: \Recommendation.createdAt, order: .reverse)
    private var recommendations: [Recommendation]

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }

    /// The three gate stages (needsApproval ∪ needsInput ∪ needsReview),
    /// oldest-first with a uid tiebreak — the same pure helper the Agent
    /// console uses (`AgentConsoleView.swift:30`), so row order never jitters
    /// and always agrees with `AgentInbox.attentionTaskCount` / the shell's
    /// `waitingCount` pill (`NotchSurface.swift`).
    private var attentionTasks: [MustardTask] {
        AgentInbox.attention(tasks).inFlight
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if pending.isEmpty && attentionTasks.isEmpty {
                    Text("Nothing waiting on you")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ForEach(pending, id: \.persistentModelID) { rec in
                    row(icon: "sparkles", title: rec.title, subtitle: "Approval waiting")
                }
                ForEach(attentionTasks, id: \.persistentModelID) { task in
                    row(icon: icon(for: task.stage), title: task.title, subtitle: subtitle(for: task.stage))
                }
            }
        }
        .frame(maxHeight: 300)
    }

    /// Icon per gate stage. `.needsApproval` and `.needsReview` are both
    /// one-click-from-the-console decisions; `.needsInput` is a question
    /// the agent is waiting on an answer to (`AgentInbox.gateAction`).
    private func icon(for stage: TaskStage) -> String {
        switch stage {
        case .needsApproval: "checkmark.circle"
        case .needsInput: "questionmark.circle"
        case .needsReview: "tray.full"
        default: "tray.full"
        }
    }

    private func subtitle(for stage: TaskStage) -> String {
        switch stage {
        case .needsApproval: "Needs approval"
        case .needsInput: "Needs you"
        case .needsReview: "Needs review"
        default: stage.label
        }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#AFA9EC"))
                .frame(width: 26, height: 26)
                .background(Color(hex: "#7F77DD").opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { nav.openAgentConsole = true }
    }
}
#endif
