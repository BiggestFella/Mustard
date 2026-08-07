import SwiftUI
import SwiftData

/// The triage workspace for one recommendation — shown in the Agent console's
/// master-detail right pane. Provenance, action + confidence, reasoning, re-bucket
/// chips, original source, the editable draft, comment, and the outcome actions.
/// Lifted from the old inline `RecommendationRow` drawer (always expanded, standalone).
struct RecommendationDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    let rec: Recommendation
    @State private var commenting = false
    @State private var commentText = ""

    private var confidenceSegments: Int { Int((rec.confidence * 5).rounded(.down)) }
    private var confidenceColor: Color { Theme.confidenceColor(rec.confidence) }
    private var draftOrBody: String { rec.draft.isEmpty ? rec.body : rec.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProvenancePill(rec: rec)
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.agent)
                Text(rec.title).font(Theme.Fonts.header).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
            }
            if rec.action.isGated {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(Theme.Fonts.caption)
                    Text("\(rec.action.label) — always reviewed by you, regardless of trust level.")
                        .font(Theme.Fonts.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Palette.agentText)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.Palette.agentTintLight, in: RoundedRectangle(cornerRadius: 8))
                .help("Email, Slack, and ticket actions are always gated regardless of trust.")
            }
            actionAndConfidence
            if !rec.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHY").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(rec.reasoning).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            drawer
            outcomes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionAndConfidence: some View {
        HStack(spacing: 8) {
            Text("✦ \(rec.action.label)")
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.agentTextDeep)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.Palette.agent.opacity(0.14), in: Capsule())
            Spacer()
            Text("confidence").font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textTertiary)
            Text(String(format: "%.2f", rec.confidence))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(confidenceColor)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < confidenceSegments ? confidenceColor : Theme.Palette.surface)
                        .frame(width: 16, height: 5)
                }
            }
        }
    }

    @ViewBuilder private var drawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RE-BUCKET").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            FlowChips(selected: rec.action) { rec.action = $0 }
        }

        if let original = rec.originalSource, !original.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ORIGINAL EMAIL").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(original).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("PROPOSED DRAFT").font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            TextEditor(text: Binding(get: { rec.draft }, set: { rec.draft = $0 }))
                .font(Theme.Fonts.meta)
                .frame(minHeight: 80, maxHeight: 220)
                .padding(6)
                .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline))
        }

        if commenting {
            TextField("Feedback to the agent…", text: $commentText)
                .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                .onSubmit { agent.comment(rec, commentText); commenting = false }
        } else if !rec.comment.isEmpty {
            (Text("Comment · ").foregroundStyle(Theme.Palette.textTertiary)
                + Text(rec.comment).foregroundStyle(Theme.Palette.textSecondary))
                .font(Theme.Fonts.meta)
        }
    }

    private var outcomes: some View {
        HStack(spacing: 8) {
            if rec.action == .fyi {
                Button("Keep") { agent.keep(rec) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.accent)
                    .controlSize(.small)
                    .help("File this to your knowledge base log, then clear it.")
                Spacer()
                Button("Dismiss", role: .destructive) { rec.decision = .denied }
                    .controlSize(.small)
                    .help("You've seen it — remove it. Nothing is stored.")
            } else {
                // "Approve & run" — approving executes the action (the prototype's
                // contextual "Approve & schedule" variant is the separate Schedule button).
                Button("Approve & run") { Task { await agent.decide(rec, .approved) } }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.accent)
                    .controlSize(.small).disabled(agent.isExecuting)
                Button("Comment") { commenting.toggle(); commentText = rec.comment }
                    .controlSize(.small)
                Menu("Snooze") {
                    Button("1 hour") { agent.snooze(rec, until: .now.addingTimeInterval(3600)) }
                    Button("This evening") { agent.snooze(rec, until: SnoozeTargets.evening()) }
                    Button("Tomorrow") { agent.snooze(rec, until: SnoozeTargets.tomorrow9()) }
                }
                .controlSize(.small).fixedSize()
                Button("Schedule") {
                    rec.decision = .scheduled
                    let task = MustardTask(title: rec.title); task.notes = draftOrBody
                    let cal = Calendar.current
                    if let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) {
                        task.scheduledAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
                        PersonalBoard.normalizePlacement(task)
                    }
                    context.insert(task)
                }
                .controlSize(.small)
                Button("I'll do it") {
                    rec.decision = .selfExecute
                    let task = MustardTask(title: rec.title); task.notes = draftOrBody
                    context.insert(task)
                }
                .controlSize(.small)
                Spacer()
                Button("Reject", role: .destructive) { rec.decision = .denied }
                    .controlSize(.small)
            }
        }
    }

}
