import SwiftUI

/// The caret-anchored "/" command menu (Craft spec 2026-07-06, 2b Task 7; grouped
/// sections added 2026-07-12, Phase 2 / BAK-251). Pure render + dispatch: rows
/// come from `SlashMenu.items(query:)`, the keyboard selection is owned by the
/// text-view coordinator (which intercepts ↑/↓/⏎ while open and tracks a single
/// flat `selectedIndex` into that same array), and a click routes the command
/// back through `onPick` → `MarkdownEditorProxy` → the one undo-safe insertion
/// path. Grouping here is presentation only — quiet-caps section headers over
/// the SAME flat, filtered array; `selectedIndex` still indexes into `items`
/// directly (not into a per-group sub-list), so the coordinator's ↑/↓/⏎/Esc
/// handling in `MarkdownTextView.doCommandBy` needs no changes at all.
struct SlashMenuView: View {
    let query: String
    let selectedIndex: Int
    let onPick: (SlashCommand) -> Void

    private static let menuWidth: CGFloat = 240
    private static let menuMaxHeight: CGFloat = 360

    var body: some View {
        let items = SlashMenu.items(query: query)
        let clampedSelection = min(selectedIndex, items.count - 1)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SlashCommand.Group.allCases, id: \.self) { group in
                        let rows = Array(items.enumerated()).filter { $0.element.group == group }
                        if !rows.isEmpty {
                            sectionHeader(group)
                            ForEach(rows, id: \.element.id) { index, command in
                                row(command, isSelected: index == clampedSelection)
                                    .id(command.id)
                            }
                        }
                    }
                }
                .padding(6)
            }
            // The list overflows menuMaxHeight (16 rows + 4 group headers), and
            // ↑/↓ selection is coordinator-owned — without this the highlight
            // walks off-screen with no visual trace (BAK-251 review finding).
            .onChange(of: clampedSelection) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: nil)
            }
        }
        .frame(width: Self.menuWidth, alignment: .leading)
        .frame(maxHeight: Self.menuMaxHeight)
        .elevation(.pop, cornerRadius: Theme.Metrics.rXl)
    }

    /// Quiet caps section label ("HEADINGS", "BASIC BLOCKS", …) — matches the
    /// reference shot's understated group divider, no background or rule line.
    private func sectionHeader(_ group: SlashCommand.Group) -> some View {
        Text(group.rawValue.uppercased())
            .font(Theme.Fonts.caption.weight(.medium))
            .foregroundStyle(Theme.Palette.textSecondary)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        Button {
            onPick(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 18)
                Text(command.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.Palette.navActive : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.rMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
