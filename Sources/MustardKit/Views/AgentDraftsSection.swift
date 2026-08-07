import SwiftUI
import SwiftData

/// The task's agent drafts, shown and edited in place (the task detail opens over the
/// board, so nothing navigates away). Each draft is a vault markdown file read live; the
/// expanded editor is the shared MarkdownTextView, autosaving back to the file.
public struct AgentDraftsSection: View {
    let run: AgentRun
    public init(run: AgentRun) { self.run = run }

    private var drafts: [AgentDraft] {
        (run.drafts ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    public var body: some View {
        if !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("DRAFTS")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ForEach(drafts, id: \.uid) { draft in
                    AgentDraftCard(draft: draft, workingDirectory: run.workingDirectory)
                }
            }
        }
    }
}

private struct AgentDraftCard: View {
    let draft: AgentDraft
    let workingDirectory: String
    /// REQUIRES `AgentDraftPanelState` in the environment or SwiftUI traps at render.
    /// Every host that presents `TaskDetailSheet` must inject it — today that is
    /// `TaskDetailDrawerModifier` and `ConsoleTaskSheet` (AgentConsoleView). A new
    /// host (preview, sheet, widget) that forgets `.environment(...)` will crash the
    /// first time a task WITH drafts is opened through it, which smoke tests miss.
    @Environment(AgentDraftPanelState.self) private var panel
    @State private var snippet: String = ""

    private var isOpen: Bool { panel.draft === draft }

    var body: some View {
        Button { panel.open(draft, workingDirectory: workingDirectory) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: icon).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.agent)
                    Text(draft.title).font(Theme.Fonts.body).fontWeight(.medium)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(draft.kind.rawValue)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.agentText)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Theme.Palette.agentTintLight, in: Capsule())
                }
                if isOpen {
                    Text("Open — editing beside this panel")
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.agentText)
                } else {
                    Text(snippet.isEmpty ? "Open draft" : snippet)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.Palette.hairline).frame(width: 2)
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isOpen ? Theme.Palette.agent : Theme.Palette.hairline,
                        lineWidth: isOpen ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .task(id: draft.uid) {
            // Resolved-URL read: a symlink planted in the drafts folder must not
            // leak outside-vault content into the card snippet.
            snippet = AgentDrafts.resolvedDraftURL(root: workingDirectory, relativePath: draft.relativePath)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
    }

    private var icon: String {
        switch draft.kind {
        case .email: return "envelope"
        case .message: return "message"
        case .comment: return "text.bubble"
        case .note, .other: return "doc.text"
        }
    }
}
