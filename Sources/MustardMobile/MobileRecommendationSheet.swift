import SwiftUI
import SwiftData

/// Mobile triage-detail bottom sheet (BAK-115): the *recommendation* half of the shared
/// task/rec sheets (the task half shipped as MobileTaskSheet in BAK-113). Mirrors the
/// desktop RecommendationDetailView — provenance, action + confidence, WHY, re-bucket
/// chips, original source, editable draft, comment — with a compact mobile footer that
/// dispatches the tested AgentService triage decisions. On iOS the agent's execution is
/// a Mac-only no-op (ADR-0003), so "Approve & run" records the decision + stages the
/// action; nothing is sent from the phone. Presented by the Triage tab (BAK-119 deck).
struct MobileRecommendationSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Environment(\.dismiss) private var dismiss
    @Bindable var rec: Recommendation

    @State private var commenting = false
    @State private var commentText = ""

    private let agentPurple = Theme.Palette.agent
    private let agentText = Theme.Palette.agentTextDeep
    /// Re-bucket options — the full action set, matching the desktop FlowChips.
    private let rebucket = RecommendationAction.allCases

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    provenance
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(agentPurple)
                        Text(rec.title).font(.title3.bold())
                    }
                    if rec.action.isGated { gatedBanner }
                    actionAndConfidence
                    if !rec.reasoning.isEmpty { section("WHY", rec.reasoning) }
                    rebucketChips
                    if let original = rec.originalSource, !original.isEmpty {
                        section("ORIGINAL SOURCE", original)
                    }
                    draftEditor
                    commentBlock
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Provenance

    private var provenance: some View {
        let badge = SourceBadge.badge(forRaw: rec.source)
        return HStack(spacing: 6) {
            if badge.isQuiet {
                Text(badge.label.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    SourceLogo(source: badge.id, size: 12)
                    Text(badge.label)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: badge.fgHex))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color(hex: badge.bgHex), in: Capsule())
            }
            if !rec.sourceContext.isEmpty {
                Text("· \(rec.sourceContext)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let s = rec.sourceURL, let url = URL(string: s) {
                Link("Open ↗", destination: url).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var gatedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock").font(.caption2)
            Text("\(rec.action.label) — always reviewed by you, regardless of trust level.")
                .font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(agentText)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.Palette.agentTintFaint, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionAndConfidence: some View {
        HStack(spacing: 8) {
            Text("✦ \(rec.action.label)")
                .font(.caption.weight(.medium)).foregroundStyle(agentText)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(agentPurple.opacity(0.14), in: Capsule())
            Spacer()
            Text(String(format: "%.2f", rec.confidence))
                .font(.caption.weight(.medium)).foregroundStyle(Theme.confidenceColor(rec.confidence))
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < Int((rec.confidence * 5).rounded(.down)) ? Theme.confidenceColor(rec.confidence) : Theme.Palette.confidenceUnfilled)
                        .frame(width: 16, height: 5)
                }
            }
        }
    }

    private var rebucketChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RE-BUCKET").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(rebucket) { a in
                        let active = rec.action == a
                        Button { rec.action = a } label: {
                            Text(a.label).font(.caption.weight(.medium))
                                .foregroundStyle(active ? .white : .secondary)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(active ? AnyShapeStyle(agentPurple) : AnyShapeStyle(Theme.Palette.surface), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROPOSED DRAFT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            TextEditor(text: $rec.draft)
                .font(.subheadline).scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 220)
                .padding(8)
                .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        }
    }

    @ViewBuilder private var commentBlock: some View {
        if commenting {
            TextField("Feedback to the agent…", text: $commentText)
                .textFieldStyle(.roundedBorder).font(.subheadline)
                .onSubmit { agent.comment(rec, commentText); commenting = false }
        } else if !rec.comment.isEmpty {
            (Text("Comment · ").foregroundStyle(.tertiary) + Text(rec.comment).foregroundStyle(.secondary))
                .font(.caption)
        }
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    // MARK: Footer — outcome actions (compact mirror of the desktop matrix)

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if rec.action == .fyi {
                Button("Dismiss", role: .destructive) { rec.decision = .denied; dismiss() }
                Spacer()
                Button("Keep") { agent.keep(rec); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.accent)
            } else {
                Button("Reject", role: .destructive) { rec.decision = .denied; dismiss() }
                Spacer()
                Menu("More") {
                    Menu("Snooze") {
                        Button("1 hour") { agent.snooze(rec, until: .now.addingTimeInterval(3600)) }
                        Button("This evening") { agent.snooze(rec, until: SnoozeTargets.evening()) }
                        Button("Tomorrow") { agent.snooze(rec, until: SnoozeTargets.tomorrow9()) }
                    }
                    Button("Schedule") { Task { await agent.decide(rec, .scheduled); dismiss() } }
                    Button("I'll do it myself") { Task { await agent.decide(rec, .selfExecute); dismiss() } }
                    Button(commenting ? "Cancel comment" : "Comment") { commentText = rec.comment; commenting.toggle() }
                }
                Button(rec.action.isGated ? "Approve & run" : "Approve") {
                    Task { await agent.decide(rec, .approved); dismiss() }
                }
                .buttonStyle(.borderedProminent).tint(agentPurple)
                .disabled(agent.isExecuting)
            }
        }
        .font(.subheadline)
        .padding()
        .background(.bar)
    }

}
