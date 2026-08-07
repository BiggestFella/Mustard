import SwiftUI

public extension View {
    /// Present the opened task as a docked right-side drawer that reflows the content
    /// to its left, instead of a centered modal sheet. Setting `item` slides the panel
    /// in; the sheet's Done / delete / gate actions clear `item` via its `onClose`.
    /// Applied at each surface that opens a task (Today, Week, Board, Lists, notch),
    /// so a task always opens in the same panel — the tap target the redesigned rows
    /// and cards point at.
    func taskDetailDrawer(item: Binding<MustardTask?>) -> some View {
        modifier(TaskDetailDrawerModifier(item: item))
    }
}

private struct TaskDetailDrawerModifier: ViewModifier {
    @Binding var item: MustardTask?
    @State private var draftPanel = AgentDraftPanelState()

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if item != nil, draftPanel.draft != nil {
                Divider().overlay(Theme.Palette.hairline)
                AgentDraftPanelView(state: draftPanel)
                    .frame(width: 440)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let task = item {
                Divider().overlay(Theme.Palette.hairline)
                TaskDetailSheet(task: task, onClose: { item = nil })
                    // Stable identity per task so swapping A→B while the drawer is open
                    // rebuilds the sheet and re-seeds its scheduled/due @State from the
                    // new task (otherwise SwiftUI reuses the view and keeps A's toggles).
                    .id(task.uid)
                    .frame(width: 460)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .environment(draftPanel)
            }
        }
        // Animate only on open / close / task-swap, not on unrelated content changes.
        .animation(Theme.Motion.expand, value: item?.uid)
        .animation(Theme.Motion.expand, value: draftPanel.draft?.uid)
        // Closing or swapping the task closes its companion draft.
        .onChange(of: item?.uid) { _, _ in draftPanel.close() }
    }
}
