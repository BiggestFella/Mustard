import SwiftUI

/// The caret-anchored `[[` note-title picker (Notes polish pack D). Pure render +
/// dispatch, mirroring `SlashMenuView`: rows come from the SAME pure functions the
/// coordinator's keyboard handling reads (`WikilinkAutocomplete.candidates` + the
/// trailing Create row for a non-blank query), `selectedIndex` is coordinator-owned,
/// and clicks route back through `onPick`/`onCreate` → `MarkdownEditorProxy` → the
/// one undo-safe insertion path.
struct WikilinkAutocompleteView: View {
    let query: String
    let selectedIndex: Int
    let titles: [String]
    let onPick: (String) -> Void
    let onCreate: (String) -> Void

    private static let menuWidth: CGFloat = 260
    private static let menuMaxHeight: CGFloat = 300

    var body: some View {
        let candidates = WikilinkAutocomplete.candidates(query: query, titles: titles)
        let showCreate = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rowCount = candidates.count + (showCreate ? 1 : 0)
        let clampedSelection = min(selectedIndex, rowCount - 1)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, title in
                        row(icon: "doc.text", label: title,
                            isSelected: index == clampedSelection) { onPick(title) }
                            .id(index)
                    }
                    if showCreate {
                        row(icon: "plus.circle", label: "Create “\(query)”",
                            isSelected: candidates.count == clampedSelection) { onCreate(query) }
                            .id(candidates.count)
                    }
                }
                .padding(6)
            }
            // Keep the coordinator-owned highlight on-screen as ↑/↓ walks a list
            // taller than menuMaxHeight (same fix as SlashMenuView / BAK-251).
            .onChange(of: clampedSelection) { _, index in
                guard index >= 0, index < rowCount else { return }
                proxy.scrollTo(index, anchor: nil)
            }
        }
        .frame(width: Self.menuWidth, alignment: .leading)
        .frame(maxHeight: Self.menuMaxHeight)
        .elevation(.pop, cornerRadius: Theme.Metrics.rXl)
    }

    private func row(icon: String, label: String, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 18)
                Text(label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
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
