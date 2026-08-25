import SwiftUI
import SwiftData

/// The triage workspace for one recommendation — shown in the Agent console's
/// master-detail right pane. Provenance, action + confidence, reasoning, re-bucket
/// chips, original source, the editable draft, comment + re-run, and the outcome
/// actions. Lifted from the old inline `RecommendationRow` drawer (always expanded,
/// standalone).
struct RecommendationDetailView: View {
    @Environment(AgentService.self) private var agent
    @Environment(HotKeyBindingsStore.self) private var hotKeys
    @Environment(GmailService.self) private var gmail
    let rec: Recommendation
    @State private var commenting = false
    @State private var commentText = ""
    @State private var confirmingSend = false
    @State private var gmailActionRunning = false

    private var confidenceSegments: Int { Int((rec.confidence * 5).rounded(.down)) }
    private var confidenceColor: Color { Theme.confidenceColor(rec.confidence) }

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
            gmailActions
            outcomes
            keyHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The triage keys, taught once under the buttons rather than stamped on
    /// each one. Reads the live chords, so a rebind shows here immediately.
    private var keyHint: some View {
        let key: (HotKeyAction) -> String = { hotKeys.chord(for: $0).description }
        return Text(
            rec.action == .fyi
                ? "\(key(.triageApprove)) keep · \(key(.triageIgnore)) dismiss · \(key(.triageSnooze)) snooze · \(key(.triageNext))/\(key(.triagePrevious)) move"
                : "\(key(.triageApprove)) approve · \(key(.triageIgnore)) ignore · \(key(.triageSnooze)) snooze · \(key(.triageNext))/\(key(.triagePrevious)) move"
        )
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Palette.textTertiary)
        .help("Editable in Settings → Hotkeys. Ignored while you're typing.")
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
                .onSubmit { saveComment() }
            commentActions
        } else if !rec.comment.isEmpty {
            (Text("Comment · ").foregroundStyle(Theme.Palette.textTertiary)
                + Text(rec.comment).foregroundStyle(Theme.Palette.textSecondary))
                .font(Theme.Fonts.meta)
            commentActions
        }
        if let error = agent.lastError, error.hasPrefix("Re-run") || error.contains("no vault to re-run") {
            Text(error)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.error)
        }
    }

    /// Explicit, per-card Gmail actions (ADR-0012). These are the ONLY paths that
    /// touch the real mailbox — never Approve, never trust auto-approve.
    @ViewBuilder private var gmailActions: some View {
        if rec.source == SourceID.gmail.rawValue,
           let messageID = rec.sourceEventID, !messageID.isEmpty,
           gmail.state == .connected {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if rec.action == .draftEmail {
                        Button("Send reply via Gmail") { confirmingSend = true }
                            .controlSize(.small).tint(Theme.Palette.accent)
                            .disabled(gmailActionRunning ||
                                      rec.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Sends the draft above as a reply on the original thread. Nothing sends without this click.")
                            .confirmationDialog("Send this reply via Gmail?",
                                                isPresented: $confirmingSend) {
                                Button("Send reply") { Task { await sendGmailReply(messageID) } }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Replies on the original thread with the current draft.")
                            }
                    }
                    Button("Archive in Gmail") { Task { await archiveGmail(messageID) } }
                        .controlSize(.small)
                        .disabled(gmailActionRunning)
                        .help("Removes the email from your Gmail inbox (never deletes) and files this card.")
                    Spacer()
                }
                if let error = gmail.lastActionError {
                    Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
                }
            }
        }
    }

    private func sendGmailReply(_ messageID: String) async {
        gmailActionRunning = true
        defer { gmailActionRunning = false }
        guard await gmail.sendReply(toMessageID: messageID, body: rec.draft) else { return }
        agent.keep(rec)   // sent = handled: file to the inbox log, clear the card
    }

    private func archiveGmail(_ messageID: String) async {
        gmailActionRunning = true
        defer { gmailActionRunning = false }
        guard await gmail.archive(messageID: messageID) else { return }
        agent.keep(rec)
    }

    private var outcomes: some View {
        HStack(spacing: 8) {
            if rec.action == .fyi {
                Button("Keep") { agent.keep(rec) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.accent)
                    .controlSize(.small)
                    .help("File this to your knowledge base log, then clear it.")
                Spacer()
                Button("Dismiss", role: .destructive) { Task { await agent.decide(rec, .denied) } }
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
                    .help("Leave guidance for the agent, then re-run to revise this proposal.")
                Menu("Snooze") {
                    Button("1 hour") { agent.snooze(rec, until: .now.addingTimeInterval(3600)) }
                    Button("This evening") { agent.snooze(rec, until: SnoozeTargets.evening()) }
                    Button("Tomorrow") { agent.snooze(rec, until: SnoozeTargets.tomorrow9()) }
                }
                .controlSize(.small).fixedSize()
                Button("Schedule") { Task { await agent.decide(rec, .scheduled) } }
                    .controlSize(.small)
                Button("I'll do it") { Task { await agent.decide(rec, .selfExecute) } }
                    .controlSize(.small)
                Spacer()
                Button("Reject", role: .destructive) { Task { await agent.decide(rec, .denied) } }
                    .controlSize(.small)
            }
        }
    }

    private var canRevise: Bool {
        let text = commenting ? commentText : rec.comment
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rec.decision == .pending
    }

    private var commentActions: some View {
        HStack(spacing: 8) {
            if commenting {
                Button("Save comment") { saveComment() }
                    .controlSize(.small)
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(agent.isSweeping ? "Revising…" : "Re-run with comment") {
                Task { await rerunWithComment() }
            }
            .controlSize(.small)
            .tint(Theme.Palette.agent)
            .disabled(!canRevise || agent.isSweeping || agent.isExecuting)
            .help("Ask the agent to re-propose this using your comment as guidance.")
        }
    }

    private func saveComment() {
        agent.comment(rec, commentText)
        commenting = false
    }

    private func rerunWithComment() async {
        let text = commenting ? commentText : rec.comment
        commenting = false
        await agent.commentAndRevise(rec, text)
    }

}
