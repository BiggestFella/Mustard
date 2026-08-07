# Craft editor — full markdown hiding + menu system — design spec

- **Date:** 2026-07-12
- **Status:** Approved (Leon, brainstorm session 2026-07-12) — ready to plan/build
- **Tracker:** Linear epic **BAK-248** (BakingLions / Mustard); sub-issues
  **BAK-249** (Phase 0), **BAK-250** (Phase 1), **BAK-251** (Phase 2),
  **BAK-252** (Phase 3), **BAK-253** (Phase 4)
- **Visual reference:** four reference screenshots Leon shared — an insert/slash menu
  (Tolaria), a text-style menu, an "Assistant" contextual menu (List / Text Style /
  Actions / Decorations / Color / Indentation / Alignment), and a list-type submenu
  (Todo / Toggle / Bullet / Numbered / No List) — all from Craft.
- **Supersedes/affects:**
  - **Extends F22 / BAK-241** (Notes Phase C — inline rich Craft-style editor). That
    work removed the Source/Preview toggle and shipped a 5-command flat slash menu
    (`Logic/SlashMenu.swift`), block drag-reorder (`Logic/BlockReorder.swift`), and
    styling-as-you-type that **dims** markdown syntax markers rather than hiding them
    (`Logic/NoteDecoration.swift`, `Views/MarkdownTextView.swift`).
  - Storage is **unchanged**: the vault `.md` file stays the source of truth. Nothing
    in this spec introduces a block database — every affordance below edits markdown
    text ranges, same constraint F22 established.
  - Nothing existing is removed; `MarkdownPreviewView` (used for read-only rendering
    elsewhere, e.g. task-notes preview) is untouched.

## Why

Leon wants the Notes editor to go further toward actual Craft parity: markdown syntax
should disappear (not just dim) when you're not editing that line, and the editor needs
Craft's richer menu surface — a bigger insert menu, a way to convert an existing block to
a different type, and a floating inline-formatting toolbar. F22 shipped the live-editor
foundation; this is the next slice on top of it.

## Current state (confirmed by code read, 2026-07-12)

- `Views/NoteEditorView.swift` — no raw/preview toggle; one always-editable
  `MarkdownTextView` + `BlockGutterOverlay` + slash-menu overlay + `BacklinksPanel`.
- `Views/MarkdownTextView.swift` — `NSViewRepresentable` over a TextKit-1 `NSTextView`;
  applies `NoteDecoration` spans (headings sized, markers de-emphasized but still
  visible, bold/italic/inline-code/wikilinks styled); handles slash-menu trigger
  detection and block-reorder splices; custom `CardLayoutManager` draws subpage cards
  behind bare wikilink lines.
- `Views/SlashMenuView.swift` — flat single-level popup, no submenus.
- `Logic/SlashMenu.swift` — exactly 5 commands: To-do, Heading (one level), Link to
  note, Sub-page, Ask the agent. Flat word-prefix filtering.
- `Logic/NoteDecoration.swift` — read-only markdown → styled-span mapping; block
  partitioning today covers frontmatter, fence, heading, rule, quote, bullet, ordered,
  text — **no table block type**. Explicitly has no rewrite API.
- `Logic/BlockReorder.swift` — pure whole-document splice `move(from:to:)`, the only
  other source-mutating function besides `SlashMenu.insertion`.
- No text-style menu, no nested contextual "Assistant" menu, no block-retype ("turn
  into") logic anywhere in the codebase — confirmed by a targeted search across
  `Views/`, `Logic/`, and `docs/`. All four screenshot menus are net-new scope.

## Scope decisions (from brainstorm, 2026-07-12)

1. **Fully hide markdown syntax** (not just dim) — markers disappear when the cursor
   isn't on that block/line, reappear on focus for editing. Biggest technical risk in
   this spec (same category of risk F22 flagged for the original live-editor work).
2. **Build all four menu systems**, phased into one epic.
3. **Skip items with no clean markdown representation**: Color, Indentation, Alignment,
   Page/Card block types (Craft's nested-container blocks), Video/Audio/File embeds,
   Mermaid diagrams, and inline **image preview rendering** (image insert still writes
   `![]()` syntax — just no live thumbnail). These get a "considered, deferred" line
   each; revisit only if a future need is concrete.
4. **Tracker:** draft here in `docs/build-order.md` + this spec, *and* file as a Linear
   epic + sub-issues (BakingLions / Mustard project) so it can be picked up the same way
   as BAK-145/BAK-241 were.

## Architecture: one shared `BlockKind` model

Today `SlashMenu` and `NoteDecoration` each have their own ad-hoc idea of "block type."
Bolting on a "turn into" menu and a block-actions menu independently would duplicate and
drift (e.g. "convert to numbered list" logic implemented once at insert-time and again
at retype-time). This spec introduces one canonical enum:

```swift
enum BlockKind {
    case paragraph, heading(Int)   // 1...4
    case quote
    case bulletList, numberedList, todoList
    case codeBlock
    case divider
    case table
    case image
    case subpage
}
```

`NoteDecoration`'s block partitioner is extended to classify each block as a `BlockKind`
(it already does most of this work under different, private names). `SlashMenu` (insert),
the new "turn into" transform, and the round-trip test all consume this one enum — one
place to add a block type, three consumers automatically get it.

## Scope — five phases, dependency-ordered

Each phase is independently shippable and reviewable; later phases depend on earlier
ones being merged, matching how F22 (BAK-241) was sequenced.

| Phase | What | Risk | Depends on |
|---|---|---|---|
| **0. Shared `BlockKind` model** | Extract the canonical block-type enum from `NoteDecoration`'s existing partitioner; no user-visible change | Low-Med | — |
| **1. Fully-hidden markdown** | `NoteDecoration`/`MarkdownTextView` hide syntax markers (`##`, `**`, `` ` ``, `- [ ]`, `>`) outside the focused block/line; reveal on cursor-enter | **High** (NSTextView) | 0 |
| **2. Expanded insert (`/`) menu** | Grow `SlashMenu`/`SlashMenuView` to: Heading 1-4, Quote, Bullet/Numbered/Check List, Paragraph, Code Block, Divider, Table, Image (syntax-only), Sub-page, Ask the agent | Medium | 0 |
| **3. "Turn into" + block actions menu** | Right-click / block-handle menu: convert current block to any `BlockKind`, Duplicate, Delete, Move up/down. Replaces the List-submenu concept, generalized to all types | Medium | 0, 2 |
| **4. Inline formatting toolbar** | Floating toolbar on text selection: Bold, Italic, Strikethrough, Inline code, Highlight, Link | Low-Med | 0 |

**Explicitly out of scope (considered, deferred):** Color, Indentation, Alignment,
Page/Card block types, Video/Audio/File embeds, Mermaid, inline image preview rendering
(recorded in Scope decision 3 above) — same "considered but deferred" pattern as F22's
dark-mode/focus-mode/cover-image log.

## Failure / edge behaviour

- **Hide-on-blur with an active selection spanning hidden markers:** selection anchors
  must stay stable when markers hide/reveal — a range-based (not character-count-based)
  reveal keeps the cursor position correct across the transition.
- **"Turn into" on a block that can't cleanly convert** (e.g. table → heading): pick the
  block's plain-text content and drop table structure rather than corrupting markdown;
  never leave malformed syntax on disk.
- **Round-trip guarantee holds**: every new `BlockKind` must satisfy
  `parse(render(source)) == source` for its supported grammar, same guard F22 established
  in `NoteDecorationTests`.
- **Large notes:** hide/reveal decoration stays range-scoped and debounced, same
  safeguard as F22's decoration pass; never blocks typing.

## Testing (per CLAUDE.md testing rules)

- Pure logic is **TDD, tests first**: `BlockKind` classification, the "turn into"
  transform, inline-formatting insertion, and the expanded `SlashMenu` filtering — all
  with fixtures, following `NoteDecorationTests`/`SlashMenuTests`/`BlockReorderTests`
  conventions. Round-trip test extended to cover every new `BlockKind`.
- Views (hide/reveal behavior, the three new menus, the floating toolbar) are **build +
  Leon's eye-check** — the agent cannot screenshot the native app (no Screen
  Recording/TCC in-session); it will state the app builds and runs, not that a view
  "looks right."
- Each phase is a separate PR behind `.agent-loop/checks.yml`.

## Risk classification (per `.agent-loop/risk.yml`)

All five phases touch only `Sources/MustardKit/{Logic,Views}/` — no auth, secrets,
`ClaudeRunner`, or `TrustPolicy` paths. Path-risk = **medium** ("Sources/" bucket);
label `risk:medium`, auto-merges on green CI + passing fresh-context review, same as
BAK-241.

## Decision log

1. Leon: "i want the document editor to be more like craft... And i want the editor to
   have options like the attached images" (four Tolaria/Craft screenshots) →
   brainstormed scope against the current F22 implementation.
2. Confirmed by code read: the Source/Preview toggle is already gone (F22/BAK-241
   shipped it); markdown is *dimmed*, not hidden; none of the four screenshot menus
   exist yet — this is genuinely unplanned scope, not a regression.
3. Leon resolved four open decisions (2026-07-12): fully hide markdown like Craft (not
   just dim); build all four menus as one phased epic; skip Color/Indentation/
   Alignment/Page-Card/embeds/Mermaid/image-preview as non-portable; track in both
   `docs/build-order.md` and a Linear epic (BakingLions / Mustard).

## Open questions / risks

- **Hide-on-blur (Phase 1)** is the real cost centre and schedule risk, same category as
  F22's original live-editor risk — Phase 0 (shared `BlockKind`) is deliberately
  sequenced first as a low-risk foundation so Phase 1 can be de-risked independently.
- **"Turn into" fidelity (Phase 3)** — converting between structurally different block
  types (e.g. table → paragraph) always loses information by nature; the contract is
  "never corrupt the file," not "never lose formatting."
