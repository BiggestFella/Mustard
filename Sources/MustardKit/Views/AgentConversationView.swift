import SwiftUI
import SwiftData

/// The durable agent conversation for a task: a scrollable transcript plus the reply /
/// review controls. Every command routes through `AgentTaskCoordinator` — this view never
/// mutates the task's owner or stage directly. Shown in the task detail flow whenever the
/// task has an `AgentRun`.
public struct AgentConversationView: View {
    @Environment(AgentTaskCoordinator.self) private var taskAgent
    @Environment(\.openURL) private var openURL
    @Bindable var task: MustardTask
    @State private var replyText = ""
    @State private var feedbackText = ""

    public init(task: MustardTask) { self.task = task }

    private var run: AgentRun? { task.agentRun }
    private var messages: [AgentMessage] { run?.orderedMessages ?? [] }

    private var canSendReply: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canRequestChanges: Bool {
        !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Conversation")
                transcript
                if run.requiresConnectedWorker { connectedBanner }
                switch task.stage {
                case .needsInput: replyComposer
                case .needsReview: reviewControls
                default: EmptyView()
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.06)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(messages, id: \.uid) { message in
                messageRow(message)
            }
        }
    }

    @ViewBuilder private func messageRow(_ message: AgentMessage) -> some View {
        switch message.role {
        case .system:
            Text(message.content)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .human:
            bubble(message, tint: Theme.Palette.accent.opacity(0.12),
                   fg: Theme.Palette.textPrimary, alignment: .trailing)
        case .agent:
            bubble(message, tint: Theme.Palette.agentTintLight,
                   fg: Theme.Palette.textPrimary, alignment: .leading)
        }
    }

    private func bubble(
        _ message: AgentMessage, tint: Color, fg: Color, alignment: HorizontalAlignment
    ) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.content)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(fg)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(message.links, id: \.url) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            Label(link.label.isEmpty ? link.url : link.label, systemImage: "link")
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(tint, in: RoundedRectangle(cornerRadius: 10))
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }

    // MARK: Connected-worker banner

    private var connectedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle").font(Theme.Fonts.caption)
            Text("Connected worker required — run the agent queue in a connected session to continue.")
                .font(Theme.Fonts.meta)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.agentText)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.Palette.agentTintLight, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Reply composer (Needs You)

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Your answer")
            HStack(spacing: 8) {
                TextField("Answer the agent…", text: $replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .lineLimit(1...5)
                    .padding(8)
                    .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline))
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.agent)
                    .disabled(!canSendReply)
            }
        }
    }

    private func send() {
        guard canSendReply else { return }
        taskAgent.reply(to: task, text: replyText)
        replyText = ""
    }

    // MARK: Review controls (Needs Review)

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Review")
            TextField("Optional: what to change…", text: $feedbackText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .lineLimit(1...5)
                .padding(8)
                .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline))
            HStack(spacing: 8) {
                Button("Request changes") { requestChanges() }
                    .controlSize(.small)
                    .disabled(!canRequestChanges)
                Button("Take back") { taskAgent.takeBack(task) }
                    .controlSize(.small)
                Spacer(minLength: 0)
                Button("Accept output") { taskAgent.accept(task) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.done).controlSize(.small)
            }
        }
    }

    private func requestChanges() {
        guard canRequestChanges else { return }
        taskAgent.requestChanges(task, feedback: feedbackText)
        feedbackText = ""
    }
}
