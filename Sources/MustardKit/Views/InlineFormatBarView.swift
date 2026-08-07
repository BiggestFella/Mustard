import SwiftUI

/// The floating inline-formatting toolbar (Craft spec 2026-07-12, Phase 4 /
/// BAK-253 — last phase of epic BAK-248): six toggles over a non-empty text
/// selection — Bold, Italic, Strikethrough, Inline code, Highlight, Link.
/// Pure render + dispatch, mirroring `SlashMenuView`'s split with the text-view
/// coordinator: this view owns no AppKit state and makes no formatting
/// decision at all — every tap just forwards the tapped `InlineFormat.Kind` to
/// `onToggle` (→ `MarkdownEditorProxy.toggleInlineFormat` → the coordinator's
/// one undo-safe splice path, `InlineFormat.toggle` + `applyWholeDocumentSplice`).
/// Color is explicitly excluded (spec scope decision 3) — six buttons, not seven.
struct InlineFormatBarView: View {
    let onToggle: (InlineFormat.Kind) -> Void

    private struct Item {
        let kind: InlineFormat.Kind
        let icon: String
        let label: String
    }

    private static let items: [Item] = [
        Item(kind: .bold, icon: "bold", label: "Bold"),
        Item(kind: .italic, icon: "italic", label: "Italic"),
        Item(kind: .strikethrough, icon: "strikethrough", label: "Strikethrough"),
        Item(kind: .inlineCode, icon: "chevron.left.forwardslash.chevron.right", label: "Inline code"),
        Item(kind: .highlight, icon: "highlighter", label: "Highlight"),
        Item(kind: .link, icon: "link", label: "Link"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items, id: \.kind) { item in
                Button {
                    onToggle(item.kind)
                } label: {
                    Image(systemName: item.icon)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.label)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .elevation(.pop, cornerRadius: Theme.Metrics.rMd)
    }
}
