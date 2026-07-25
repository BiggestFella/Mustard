# Notes Polish Pack — Design

**Date:** 2026-07-26
**Status:** Approved (design), pending spec review → plan
**Origin:** Port the "extra little features" Leon values in [Tolaria](https://tolaria.md) (open-source, Tauri/React/TS, AGPL-3.0) into Mustard Notes. This is an **idea port, not a code port** — the stacks are incompatible and AGPL copying is off the table; we reimplement the ideas natively in SwiftUI/MustardKit.

This is **slice 1 of the Tolaria port**. Slice 2 (Neighborhood: typed frontmatter relationships + Properties panel + local graph) is out of scope here and gets its own spec.

## Goal

Five small, self-contained polish features that make Mustard Notes feel as fluid as Tolaria, none requiring a schema/data-model change:

1. **Full-text search** — a dedicated search palette over note bodies.
2. **Wikilink autocomplete** — `[[` opens a note-title picker.
3. **Note width control** — readable-measure setting for the editor.
4. **Note rename / delete** — link-aware rename + safe delete from the sidebar.
5. **Wikilink hover preview** — peek a `[[link]]`'s target on hover.

## Design principles (inherited)

- **Pure decision logic in `MustardKit/Logic`, TDD first** (failing XCTest → implement). Views only render/dispatch.
- **Byte-faithful editor** — every text mutation goes through the existing `insertText(_:replacementRange:)` splice paths in `MarkdownTextView` (scoped `performSlashCommand` or `applyWholeDocumentSplice`), wrapped in undo groups. No new rewrite path.
- **Parity** (Leon's rule): all decision logic lands in shared `MustardKit/Logic` so iOS inherits it; this slice wires the **macOS** views. iOS view wiring is a tracked follow-up, consistent with current iOS parity debt.
- **Theme tokens only** — no hardcoded colors; reuse `Theme.Palette` / `Theme.Fonts`.

## Current-state anchors (what we build on)

- Sidebar filter: `NotesView.filterField` binds `filter` → `NoteTree.filter(tree, query:)`, which matches **title or filename only**. `Views/NotesView.swift:86`.
- Full content is **already indexed**: `NoteIndexEntry.contentSnapshot` holds each note's full file copy (`Models/NoteIndexEntry.swift`). Full-text search needs no new indexing.
- Command palette: pure `Logic/CommandBarEngine.swift` + `Views/CommandBarView.swift`. ⌘K overlay pattern is reusable for the search palette.
- Slash menu: pure `Logic/SlashMenu.swift` + `Views/SlashMenuView.swift`; cursor-anchored popup driven by `activeQuery` detection in `MarkdownTextView`. Reusable pattern for wikilink autocomplete.
- Wikilink graph: `Logic/WikilinkIndex.swift` (`build`, `resolve`, `resolver`) provides forwardLinks + backlinks; `Logic/WikilinkSyntax.swift` is the single regex (matches `[[T]]`, `[[T#h]]`, `[[T|alias]]`, `![[T]]`).
- Editor knows wikilink ranges already (it handles clicks + `mustard-note://` URLs): `Views/MarkdownTextView.swift`. Hover reuses that hit-testing.
- Create-from-dangling-link plumbing exists: `NotesView.createNote` + `writeNote` + `pendingWikilinkTarget` alert (`Views/NotesView.swift:236`).
- Note IO boundary: `Agent/FileVaultIO.swift` (`NoteVaultIO`: read / atomic write / notePaths). Reindex: `Agent/NoteIndexService.reindex(project:workingDirectory:)`.

---

## Feature 1 — Full-text search (dedicated palette)

**Behavior.** A standalone search overlay, styled to match the ⌘K command bar, opened by **`⌘⇧F`** and by a new **"Search notes…"** command in ⌘K. A live-updating results list: notes whose **title, filename, or body** match the query (case-insensitive), ranked, each row showing the note title + a one-line snippet of the first matching body line. Keyboard-navigable (↑/↓, Enter opens, Esc closes). Selecting a result navigates the Notes surface to that note (same `selected` flush→open chain as sidebar navigation).

**Pure logic — `Logic/NoteSearch.swift` (new).**
```
struct NoteSearchHit { let project: String; let relativePath: String; let title: String; let snippet: String? }
static func match(entries: [NoteSearchEntry], query: String) -> [NoteSearchHit]
```
- `NoteSearchEntry` is a plain value (project, relativePath, title, contentSnapshot) mapped from `NoteIndexEntry`, so the function stays SwiftData-free and testable.
- Empty/whitespace query → `[]` (palette shows an idle hint, not the whole vault).
- Ranking: title match > filename match > body match; then by `title` alphabetical. (Simple, deterministic, testable — no fuzzy scoring in this slice.)
- `snippet`: for body-only hits, the first content line containing the query, trimmed; `nil` when the match is title/filename (the title row already shows it). Reuse the first-matching-line approach from `Logic/BacklinkSnippets.swift`.
- Fenced code lines are **not** excluded (search should find code); note this explicitly in the test.

**View — `Views/NoteSearchView.swift` (new)** + a small host hook in the Notes surface / app chrome for the `⌘⇧F` shortcut and the ⌘K "Search notes…" entry. Reuse `CommandBarView`'s overlay styling. The view is thin: query field + `List(NoteSearch.match(...))` + selection dispatch.

**Wiring.** Add `CommandKind.searchNotes` + a `CommandItem` to `CommandBarEngine` (keeps the palette openable from ⌘K). The ⌘K command opens the same `NoteSearchView`.

**Tests (`Tests/MustardTests/NoteSearchTests.swift`):** empty query → empty; title/filename/body match inclusion; body-only produces a snippet, title match does not; ranking order (title before body); case-insensitivity; multi-project entries stay project-labeled.

---

## Feature 2 — Wikilink autocomplete

**Behavior.** Typing `[[` in the editor opens a cursor-anchored popup (reuse `SlashMenuView` machinery/anchoring) listing note titles matching the text typed after `[[` (before any closing `]]`). Enter/click inserts `[[Title]]` (auto-closing the brackets) and dismisses. A bottom **"Create '<query>'"** row creates a new note via the existing create-from-link plumbing and inserts the link. Esc dismisses, leaving typed text untouched.

**Pure logic — `Logic/WikilinkAutocomplete.swift` (new).**
```
struct WikilinkQuery { let range: NSRange; let text: String }   // the [[… span before the caret
static func activeQuery(line: String, caretUTF16Offset: Int) -> WikilinkQuery?
static func candidates(query: String, titles: [String]) -> [String]   // ranked, case-insensitive prefix-then-contains
```
- `activeQuery` finds the nearest unclosed `[[` on the caret's line with no intervening `]]`; returns the query text + its range. Returns `nil` when not inside an open wikilink.
- `candidates` ranks prefix matches above substring matches, then alphabetical; excludes exact-duplicate titles gracefully.

**View/wiring.** In `MarkdownTextView`, detect the `[[` open-query on text change (mirroring the existing `/` `activeQuery` detection) and drive the popup with `WikilinkAutocomplete.candidates`. Insertion reuses the byte-pinned `insertText` splice + undo group. The "Create" row calls back into the `NotesView` create path (thread a callback like the existing wikilink-tap callback).

**Tests (`WikilinkAutocompleteTests.swift`):** `[[` at various caret positions; open vs already-closed link; query with spaces; caret before `[[` → nil; candidate ranking (prefix before contains); empty query returns all titles (or a capped list — cap decided in plan).

---

## Feature 3 — Note width control

**Behavior.** Editor readable-measure setting: **Comfortable (~680 pt, default) · Wide (~900 pt) · Full**. The text column is max-width-constrained and centered at Comfortable/Wide; Full uses the whole pane. Persisted **globally** via `@AppStorage("noteEditorWidth")`. Control: a small width toggle (segmented or menu) in the note document header row (`NoteEditorView`, next to the dirty dot / ⌘S).

**Logic.** Trivial enough to be an enum with the pt values: `Logic/NoteEditorWidth.swift` — `enum NoteEditorWidth: String, CaseIterable { case comfortable, wide, full; var maxWidth: CGFloat? }` (`full` → `nil`). One tiny test pinning the pt values so a future edit is deliberate.

**View.** `NoteEditorView` reads the `@AppStorage` value, applies `.frame(maxWidth:)` + centering to the editor column, and renders the toggle in the header.

---

## Feature 4 — Note rename / delete (sidebar context menu)

Right-click a sidebar leaf row (`NotesView.leafRow`) → **Rename…** / **Delete…**.

### Delete
- Moves the file to the **system Trash** via `FileManager.default.trashItem(at:resultingItemURL:)` — Finder-recoverable. (Mustard isn't git-backed yet; this is the safe equivalent of Tolaria's "no trash, git recovers.")
- Confirmation dialog naming the note. On confirm: trash → `noteIndex.reindex(...)` → clear `selected` if it was the deleted note.
- Inbound links to a deleted note become dangling — acceptable; they already offer create-from-link. No link rewrite on delete.
- Extend `NoteVaultIO` with a `trash(_ relativePath:) throws` method (keeps IO at the boundary; view calls the protocol, not `FileManager` directly).

### Rename (link-aware)
- **Pure logic — `Logic/NoteRename.swift` (new):**
```
struct RenamePlan {
    let oldRelativePath: String
    let newRelativePath: String
    let linkEdits: [LinkEdit]   // per referencing note: path + new full content (or edit spans)
}
static func plan(target: NoteRef-ish, newTitle: String, index: [ParsedNote-ish]) -> RenamePlan
static func rewrite(content: String, from oldTarget: String, to newTarget: String) -> String
```
  - Computes the new filename/path from `newTitle` via `NoteCreation` sanitization + collision rules (reuse existing).
  - Uses the wikilink index's backlinks to find every referencing note, and `rewrite` replaces `[[Old]]`/`[[Old#h]]`/`[[Old|alias]]`/`![[Old]]` forms with the new target, **preserving** heading anchors and aliases (only the target segment changes). Built on `WikilinkSyntax` (single grammar) so all link forms are covered.
  - Path-qualified links (`[[folder/Old]]`) update the last component consistent with the resolver's filename-fallback rule.
- **Execution (view/service):** move the file (add `NoteVaultIO.move(from:to:) throws`), write each `linkEdit` atomically through `NoteVaultIO.write`, snapshot-before-write (mirror `NoteEditorView` save baseline), then `reindex`. Update `selected` to the new path.
- **Edge cases:** rename to an existing name → collision-count suffix (reuse `NoteCreation`); no-op rename → do nothing; rename must not touch links inside fenced code blocks (the index already skips fenced lines — the rewrite must honor the same skip).
- **Tests (`NoteRenameTests.swift`):** plan produces correct new path; rewrite handles plain/heading/alias/embed forms; path-qualified links; fenced-code links left untouched; collision suffixing; a note with zero backlinks yields an empty `linkEdits`.

*This is the heaviest item in the pack — flagged so the plan can sequence it last.*

---

## Feature 5 — Wikilink hover preview

**Behavior.** Hovering a `[[link]]` in the editor shows a popover peek of the target: title + first few body lines (from the target's `contentSnapshot`). Unresolved links show a subtle "Create note?" hint instead of a preview. Popover appears after a short hover delay and dismisses on exit; it does not steal focus or interrupt typing.

**Pure logic — `Logic/NotePreview.swift` (new):** `static func excerpt(content: String, maxLines: Int) -> String` — strips frontmatter (reuse the metadata strip used by `NoteMetadata`), returns the first `maxLines` non-empty body lines, trimmed. Testable, no view/clock deps.

**View/wiring.** In `MarkdownTextView`, add hover tracking over wikilink glyph ranges (it already computes those ranges for clicks). On hover-enter of a link range: resolve via the passed-in resolver; if resolved, look up the target entry's `contentSnapshot`, run `NotePreview.excerpt`, show an `NSPopover`/SwiftUI popover anchored to the link rect; if unresolved, show the create hint. Thread the entries/resolver already available in `NoteEditorView`'s editor builder.

**Tests (`NotePreviewTests.swift`):** frontmatter stripped; blank lines skipped; `maxLines` honored; short notes return what they have; empty content → empty string.

---

## Sequencing (for the plan)

Independent features; suggested order easiest→heaviest so value lands early:

1. **Note width control** (trivial, self-contained).
2. **Full-text search palette** (pure `NoteSearch` + thin view + ⌘K/⌘⇧F wiring).
3. **Wikilink hover preview** (`NotePreview` + hover tracking).
4. **Wikilink autocomplete** (`WikilinkAutocomplete` + popup reuse).
5. **Link-aware rename + delete** (biggest; `NoteRename`, `NoteVaultIO.move`/`trash`).

Each is a separately shippable, test-passing step (bite-sized commits per Git conventions).

## Out of scope (this slice)

- Neighborhood mode, typed frontmatter relationships, Properties panel, local graph view (slice 2).
- Git-backed version history / diffs (separate slice; delete uses system Trash in the meantime).
- Rich rendering (code syntax highlighting, LaTeX, image thumbnails, live tables) — separate slice.
- iOS view wiring (logic is shared/ready; iOS surfaces are a tracked follow-up).
- Fuzzy search scoring, search-result body highlighting beyond the single snippet line, tag/type browsing, move-between-folders drag.

## Verification

- `swift test` (whole suite) green, including the new pure-logic test files.
- `swift build` succeeds.
- macOS views verified by build + Leon's eye (the in-session shell can't screenshot the native app) — Leon confirms each surface runs and behaves.
