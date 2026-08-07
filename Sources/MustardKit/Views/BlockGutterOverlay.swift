import SwiftUI

/// Hover gutter over the live editor (Craft spec, 2b Task 9 + Phase 3 / BAK-252):
/// a narrow leading strip that surfaces `+` (insert via slash menu) and `⠿`
/// (drag-reorder, and now a right-click/context menu: "Turn into" + block
/// actions) for the hovered block. Pure geometry + dispatch — block rects arrive
/// from the text view's layout manager, the drop slot maps straight to
/// `BlockReorder.move`'s after-removal indexing, and every action routes through
/// `MarkdownEditorProxy` into the one undo-safe splice path (`MarkdownTextView
/// .Coordinator.applyWholeDocumentSplice`). The overlay's transparent regions
/// never intercept clicks meant for the text.
struct BlockGutterOverlay: View {
    let rects: [MarkdownBlockRect]
    /// `(from, to)` in moveable-block indices — after-removal semantics.
    let onMove: (Int, Int) -> Void
    /// Open the slash menu anchored at this block's start.
    let onInsert: (Int) -> Void
    /// "Turn into" — convert the block at this index to `BlockKind`.
    var onTurnInto: (Int, BlockKind) -> Void = { _, _ in }
    var onDuplicate: (Int) -> Void = { _ in }
    var onDelete: (Int) -> Void = { _ in }
    var onMoveUp: (Int) -> Void = { _ in }
    var onMoveDown: (Int) -> Void = { _ in }

    @State private var hoveredIndex: Int?
    @State private var dragFromIndex: Int?
    @State private var dropSlot: Int?

    private static let gutterWidth: CGFloat = 28
    private static let coordinateSpaceName = "mustardBlockGutter"

    /// "Turn into" menu rows — label + `BlockKind`, in the same order/wording
    /// as `SlashMenu`'s equivalent commands (Headings, then basic blocks) so
    /// the insert menu and the retype menu read as one vocabulary. Mirrors
    /// `BlockTransform.menuTargets` (the pure layer's supported target list);
    /// kept as a separate view-layer array (not derived from it) because these
    /// are DISPLAY strings, which `Logic/` deliberately has no opinion on.
    private static let turnIntoItems: [(label: String, kind: BlockKind)] = [
        ("Paragraph", .paragraph),
        ("Heading 1", .heading(1)),
        ("Heading 2", .heading(2)),
        ("Heading 3", .heading(3)),
        ("Heading 4", .heading(4)),
        ("Quote", .quote),
        ("Bullet List", .bulletList),
        ("Numbered List", .numberedList),
        ("Check List", .todoList),
        ("Code Block", .codeBlock),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.index) { block in
                    handleCell(block)
                }
                if dragFromIndex != nil, let slot = dropSlot {
                    insertionLine(width: geometry.size.width)
                        .offset(x: 0, y: insertionLineY(slot: slot) - 1)
                }
            }
        }
        // Fully-typed coordinate-space API (macOS 14): the bare `.named(...)`
        // implicit member is ambiguous between the CoordinateSpace and
        // CoordinateSpaceProtocol overloads of DragGesture.init.
        .coordinateSpace(NamedCoordinateSpace.named(Self.coordinateSpaceName))
        .animation(Theme.Motion.settle, value: hoveredIndex)
    }

    // MARK: - Per-block handles

    private func handleCell(_ block: MarkdownBlockRect) -> some View {
        let isActive = hoveredIndex == block.index || dragFromIndex == block.index
        return HStack(alignment: .top, spacing: 2) {
            Button {
                onInsert(block.index)
            } label: {
                Image(systemName: "plus")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(isActive ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Insert here")

            Text("⠿")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                .help("Drag to reorder, or right-click for more actions")
                // Deliberately NOT NSTextView's native text drag: this gesture
                // reorders whole blocks via BlockReorder, not characters.
                .gesture(dragGesture(for: block))
                // Phase 3 / BAK-252: the block handle also hosts the "Turn
                // into" + Actions context menu (right-click, or the handle's
                // own click-and-hold on trackpads without a right-click).
                // Rendered here (renders + dispatches only) — the pure
                // decision of what each row DOES lives in `BlockTransform`.
                .contextMenu {
                    blockContextMenu(for: block.index, kind: block.kind)
                }
        }
        .padding(.top, 2)
        .opacity(isActive ? 1 : 0)
        .frame(width: Self.gutterWidth, height: max(block.rect.height, 18), alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredIndex = block.index
            } else if hoveredIndex == block.index {
                hoveredIndex = nil
            }
        }
        .offset(x: 0, y: block.rect.minY)
    }

    // MARK: - Context menu (Phase 3 / BAK-252)

    /// Two sections, per spec: "Turn into" (a `Menu` submenu — Craft's own
    /// retype menu is nested exactly this way) and "Actions" (Duplicate,
    /// Delete, Move up, Move down). Move up/down disable at the document
    /// edges — `rects` is already index-contiguous (0..<rects.count), so the
    /// first/last check needs no extra state.
    ///
    /// "Turn into" is hidden entirely for a `.divider` block (Phase 3 /
    /// BAK-252 review fix): `BlockTransform.turnInto` already returns `nil`
    /// for every divider source (defense in depth — see that file's doc), but
    /// nothing upstream of this view used to act on that, so right-clicking a
    /// divider showed all ten targets as silent no-ops. `kind` is plumbed
    /// straight from `NoteDecoration.blockKind` via `MarkdownBlockRect`, so
    /// this is pure display gating, no classification logic of its own.
    @ViewBuilder
    private func blockContextMenu(for index: Int, kind: BlockKind) -> some View {
        if kind != .divider {
            Menu("Turn into") {
                ForEach(Self.turnIntoItems, id: \.label) { item in
                    Button(item.label) { onTurnInto(index, item.kind) }
                }
            }
            Divider()
        }
        Button("Duplicate") { onDuplicate(index) }
        Button("Delete") { onDelete(index) }
        Divider()
        Button("Move up") { onMoveUp(index) }
            .disabled(index <= 0)
        Button("Move down") { onMoveDown(index) }
            .disabled(index >= rects.count - 1)
    }

    // MARK: - Drag → drop slot

    private func dragGesture(for block: MarkdownBlockRect) -> some Gesture {
        DragGesture(minimumDistance: 2.0,
                    coordinateSpace: NamedCoordinateSpace.named(Self.coordinateSpaceName))
            .onChanged { value in
                dragFromIndex = block.index
                dropSlot = slot(forY: value.location.y, excluding: block.index)
            }
            .onEnded { value in
                let from = block.index
                let to = slot(forY: value.location.y, excluding: from)
                dragFromIndex = nil
                dropSlot = nil
                if to != from { onMove(from, to) }
            }
    }

    /// The insertion slot for a drop at `y`: the count of remaining blocks whose
    /// midline sits above it — exactly `BlockReorder.move`'s `to` (the slot after
    /// removing the dragged block).
    private func slot(forY y: CGFloat, excluding dragged: Int) -> Int {
        rects.filter { $0.index != dragged && $0.rect.midY < y }.count
    }

    /// Boundary y for the insertion line: the top of the block currently at the
    /// slot, or the bottom of the last block for the end slot.
    private func insertionLineY(slot: Int) -> CGFloat {
        guard let dragged = dragFromIndex else { return 0 }
        let others = rects.filter { $0.index != dragged }
        guard !others.isEmpty else { return 0 }
        if slot < others.count { return others[slot].rect.minY }
        return others[others.count - 1].rect.maxY
    }

    private func insertionLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.Palette.accent)
            .frame(width: max(width - 8, 0), height: 2)
            .padding(.leading, 4)
            .allowsHitTesting(false)
    }
}
