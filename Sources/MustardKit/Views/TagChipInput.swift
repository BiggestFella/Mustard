import SwiftUI

/// Wrapping row of chips. All the line-breaking lives in the pure, tested
/// `TagFlow`; this only measures subviews and places them.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = TagFlow.rows(itemWidths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        let rowHeight = sizes.map(\.height).max() ?? 0
        var widest: CGFloat = 0
        for row in rows {
            var rowWidth: CGFloat = 0
            for index in row { rowWidth += sizes[index].width }
            rowWidth += CGFloat(max(0, row.count - 1)) * spacing
            widest = max(widest, rowWidth)
        }
        let height = TagFlow.height(rowCount: rows.count, rowHeight: rowHeight, spacing: rowSpacing)
        return CGSize(width: maxWidth == .infinity ? widest : min(widest, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = TagFlow.rows(itemWidths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing)
        let rowHeight = sizes.map(\.height).max() ?? 0
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}

/// Editable tag chips backed by a `[String]` binding. Type + Return adds; ✕ removes.
///
/// Chips wrap onto as many rows as they need and are never compressed — a plain
/// `HStack` squeezed long tags into tall columns of broken text, which pushed
/// the rest of the detail sheet (notably the body editor) off the screen.
struct TagChipInput: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        ChipFlowLayout {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(Theme.Fonts.meta).lineLimit(1)
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textTertiary)
                }
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.Palette.surface, in: Capsule())
            }
            TextField("+ tag", text: $draft)
                .textFieldStyle(.plain).font(Theme.Fonts.meta)
                .frame(width: 70)
                .fixedSize()
                .onSubmit(add)
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !tags.contains(t) else { draft = ""; return }
        tags.append(t)
        draft = ""
    }
}
