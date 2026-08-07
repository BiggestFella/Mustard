import Foundation

/// The canonical block-type classification for the Notes editor (Craft menus spec,
/// 2026-07-12, Phase 0 / BAK-249). One shared enum so the insert (`/`) menu, the
/// future "turn into" transform, and any other block-aware surface all agree on
/// what a block IS — before this, `SlashMenu` and `NoteDecoration` each carried
/// their own ad-hoc notion of block type, which would have drifted the moment a
/// second consumer needed the same classification.
///
/// Deliberately NOT a case here: `.frontmatter`. The leading YAML block is a
/// document-level concept (there's exactly one, it's never inserted or "turned
/// into" from a menu, and it already has a home as `NoteDecoration.Block
/// .isFrontmatter` / `NoteDecoration.Kind.frontmatter` one layer down for span
/// styling) — so `NoteDecoration.blockKind(_:of:)` returns `nil` for a
/// frontmatter block rather than stretching this enum to cover it.
///
/// `heading`'s `Int` is the block's REAL heading level (1...6, whatever
/// `# `...`###### ` the source actually has) — the spec's "1...4" comment is the
/// Phase-2 insert menu's offered range, not a constraint on what existing vault
/// content can classify as. Classification must describe a block honestly; it
/// never re-renders or clamps it.
public enum BlockKind: Equatable {
    case paragraph
    case heading(Int)
    case quote
    case bulletList, numberedList, todoList
    case codeBlock
    case divider
    case table
    case image
    case subpage
}
