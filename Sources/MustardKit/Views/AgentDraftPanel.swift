import SwiftUI
import SwiftData
import AppKit

/// Presentation state for the single companion draft panel. Owned by whichever host
/// presents the task detail (the docked drawer, the console sheet) and injected into
/// the environment so AgentDraftsSection can open a draft beside the task panel.
@MainActor
@Observable
public final class AgentDraftPanelState {
    public var draft: AgentDraft?
    public var workingDirectory: String = ""
    public init() {}

    public func open(_ draft: AgentDraft, workingDirectory: String) {
        self.draft = draft
        self.workingDirectory = workingDirectory
    }

    public func close() { draft = nil }
}

/// Full-height companion editor for one agent draft — real reading width beside the
/// task panel, never a navigation away. Edits autosave to the vault file (debounced
/// and dirty-checked, flushed on close/swap — mirroring the Notes editor's
/// save-on-transition discipline rather than a write per keystroke); nothing is ever
/// sent. All file access goes through `AgentDrafts.resolvedDraftURL`, so a symlink
/// planted in the drafts folder can never route a read or write outside the vault.
public struct AgentDraftPanelView: View {
    private enum SaveState { case clean, dirty, saved, failed }

    @Bindable var state: AgentDraftPanelState
    @State private var text: String = ""
    @State private var lastWrittenText: String = ""
    @State private var loaded = false
    @State private var saveState: SaveState = .clean
    @State private var saveDebounce: Task<Void, Never>?

    public init(state: AgentDraftPanelState) { self.state = state }

    private var fileURL: URL? {
        guard let draft = state.draft else { return nil }
        return AgentDrafts.resolvedDraftURL(root: state.workingDirectory,
                                            relativePath: draft.relativePath)
    }

    public var body: some View {
        if let draft = state.draft {
            VStack(alignment: .leading, spacing: 0) {
                header(draft)
                Divider().overlay(Theme.Palette.hairline)
                if loaded {
                    MarkdownTextView(text: $text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: text) { _, _ in scheduleSave() }
                } else {
                    Text("Draft file not found — it may have been moved.")
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.warnText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(16)
                }
                Divider().overlay(Theme.Palette.hairline)
                footer
            }
            .background(Theme.Palette.bg)
            .task(id: draft.uid) { load() }
            // Swapping to another draft re-runs .task, but the OLD draft's pending
            // edit must land first; same on close/removal from the hierarchy.
            .onChange(of: draft.uid) { _, _ in flushSave() }
            .onDisappear { flushSave() }
        }
    }

    private func header(_ draft: AgentDraft) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon(draft.kind)).font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.agent)
            Text(draft.title).font(Theme.Fonts.body).fontWeight(.medium).lineLimit(2)
            Spacer(minLength: 8)
            Text(draft.kind.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.agentText)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Theme.Palette.agentTintLight, in: Capsule())
            saveBadge
            Button { flushSave(); state.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                .help("Close draft")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var saveBadge: some View {
        switch saveState {
        case .saved:
            Label("saved", systemImage: "checkmark")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
        case .failed:
            Label("couldn't save", systemImage: "exclamationmark.triangle")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.warnText)
                .help("The draft file could not be written — your edit is still in this panel; copy it before closing.")
        case .clean, .dirty:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
                .controlSize(.small).disabled(!loaded)
            Text("editing in place · autosaves · never sent")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func icon(_ kind: AgentDraftKind) -> String {
        switch kind {
        case .email: return "envelope"
        case .message: return "message"
        case .comment: return "text.bubble"
        case .note, .other: return "doc.text"
        }
    }

    private func load() {
        saveDebounce?.cancel()
        saveState = .clean
        if let url = fileURL, let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
            lastWrittenText = contents
            loaded = true
        } else {
            text = ""
            lastWrittenText = ""
            loaded = false
        }
    }

    /// Debounced autosave: settles ~600ms after the last keystroke; the dirty check
    /// makes the programmatic load (and idle re-renders) free.
    private func scheduleSave() {
        guard loaded, text != lastWrittenText else { return }
        saveState = .dirty
        saveDebounce?.cancel()
        saveDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        saveDebounce?.cancel()
        guard loaded, text != lastWrittenText else { return }
        guard let url = fileURL else {
            saveState = .failed
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastWrittenText = text
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }
}
