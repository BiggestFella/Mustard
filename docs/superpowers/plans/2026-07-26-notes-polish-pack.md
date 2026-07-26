# Notes Polish Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port five self-contained "polish" features from Tolaria into Mustard Notes — full-text search palette, `[[` wikilink autocomplete, note width control, link-aware rename + safe delete, and wikilink hover preview.

**Architecture:** Every decision goes in a pure `MustardKit/Logic` (or IO-boundary) unit, unit-tested first (TDD); macOS view wiring is thin and verified by `swift build` + Leon's eye (the in-session shell can't screenshot the native app). Pure logic is shared, so iOS inherits it later (parity rule). No new text-mutation path — editor splices reuse the existing byte-pinned `insertText` machinery.

**Tech Stack:** Swift 5.9 / SwiftUI / SwiftData / AppKit (TextKit 1), XCTest, SwiftPM (`swift test`, `swift build`).

**Spec:** `docs/superpowers/specs/2026-07-26-notes-polish-pack-design.md`

---

## Conventions (read once)

- **Logic/IO = TDD.** Write the failing XCTest, run it red, implement minimally, run it green, commit. One test file per unit under `Tests/MustardTests/`.
- **Views = build + eye.** No unit tests; each view task ends with `swift build` green and a note for Leon to eye-check. Never claim a view "looks right" — state it builds and ask Leon to confirm.
- **Commit granularity:** one commit per task (logic tasks commit test+impl together after green; view tasks commit after build).
- **Branch:** all work on `feat/notes-polish-pack` (already created; spec already committed there).
- **Theme tokens only** in views (`Theme.Palette` / `Theme.Fonts`), never hardcoded colors.
- Run the whole suite with `swift test`; a single suite with `swift test --filter <SuiteName>`.

## File Structure

**Create (pure logic + tests):**
- `Sources/MustardKit/Logic/NoteEditorWidth.swift` — width enum + pt values.
- `Sources/MustardKit/Logic/NoteSearch.swift` — full-text match + ranking + snippet.
- `Sources/MustardKit/Logic/NotePreview.swift` — hover-preview excerpt.
- `Sources/MustardKit/Logic/WikilinkAutocomplete.swift` — `[[` trigger detection + candidate ranking.
- `Sources/MustardKit/Logic/NoteRename.swift` — link-aware rename plan (retitle + rewrite).
- `Tests/MustardTests/{NoteEditorWidth,NoteSearch,NotePreview,WikilinkAutocomplete,NoteRename,FileVaultIOMutation}Tests.swift`

**Create (views):**
- `Sources/MustardKit/Views/NoteSearchView.swift` — the dedicated search palette.

**Modify:**
- `Sources/MustardKit/Logic/NoteCreation.swift` — expose two existing private helpers for reuse by `NoteRename`.
- `Sources/MustardKit/Agent/FileVaultIO.swift` — add `move` + `trash` to `NoteVaultIO` + impl.
- `Sources/MustardKit/Logic/CommandBarEngine.swift` — add a `searchNotes` command.
- `Sources/MustardKit/Views/RootView.swift` — host the search palette + `⌘⇧F` shortcut; route the `searchNotes` command.
- `Sources/MustardKit/Views/NoteEditorView.swift` — width toggle in header + `@AppStorage`-driven measure.
- `Sources/MustardKit/Views/MarkdownTextView.swift` — wikilink autocomplete popup + hover-preview tracking.
- `Sources/MustardKit/Views/NotesView.swift` — sidebar rename/delete context menu + execution; thread the search selection + autocomplete-create callbacks.

---

# Feature A — Note width control

### Task 1: `NoteEditorWidth` enum (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NoteEditorWidth.swift`
- Test: `Tests/MustardTests/NoteEditorWidthTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NoteEditorWidthTests: XCTestCase {
    func test_maxWidth_pins_point_values() {
        XCTAssertEqual(NoteEditorWidth.comfortable.maxWidth, 720)
        XCTAssertEqual(NoteEditorWidth.wide.maxWidth, 960)
        XCTAssertNil(NoteEditorWidth.full.maxWidth, "full is unconstrained (full-bleed)")
    }

    func test_allCases_and_labels() {
        XCTAssertEqual(NoteEditorWidth.allCases, [.comfortable, .wide, .full])
        XCTAssertEqual(NoteEditorWidth.wide.label, "Wide")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteEditorWidthTests`
Expected: FAIL — `cannot find 'NoteEditorWidth' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import CoreGraphics

/// Reading-measure setting for the note editor column (Notes polish pack). Persisted
/// globally via @AppStorage("noteEditorWidth"); `NoteEditorView` applies `maxWidth`.
public enum NoteEditorWidth: String, CaseIterable, Identifiable, Equatable {
    case comfortable, wide, full

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .wide: return "Wide"
        case .full: return "Full"
        }
    }

    /// nil = no constraint (full-bleed). Points, matching the prior fixed 720 measure.
    public var maxWidth: CGFloat? {
        switch self {
        case .comfortable: return 720
        case .wide: return 960
        case .full: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteEditorWidthTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NoteEditorWidth.swift Tests/MustardTests/NoteEditorWidthTests.swift
git commit -m "feat(notes): NoteEditorWidth measure enum (polish pack A)"
```

### Task 2: Wire width toggle into the editor header (View, build+eye)

**Files:**
- Modify: `Sources/MustardKit/Views/NoteEditorView.swift:45` (the `readingMeasure` constant) and `:86` (the `.frame(maxWidth:)`), header `:141-146`.

- [ ] **Step 1: Add the persisted setting.** Near the other `@State` in `NoteEditorView` (after line 41), add:

```swift
    @AppStorage("noteEditorWidth") private var widthRaw = NoteEditorWidth.comfortable.rawValue
    private var editorWidth: NoteEditorWidth { NoteEditorWidth(rawValue: widthRaw) ?? .comfortable }
```

- [ ] **Step 2: Drive the frame from the setting.** Replace line 86 `.frame(maxWidth: Self.readingMeasure)` with:

```swift
        .frame(maxWidth: editorWidth.maxWidth ?? .infinity)
```

Delete the now-unused `private static let readingMeasure: CGFloat = 720` (line 45).

- [ ] **Step 3: Add the header control.** In `header` (line 141), between `Spacer(minLength: 12)` and the `Save` button, insert a small menu:

```swift
                Menu {
                    ForEach(NoteEditorWidth.allCases) { option in
                        Button {
                            widthRaw = option.rawValue
                        } label: {
                            HStack {
                                Text(option.label)
                                if option == editorWidth { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.left.and.right")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Editor width")
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit + flag for eye-check**

```bash
git add Sources/MustardKit/Views/NoteEditorView.swift
git commit -m "feat(notes): editor width toggle (Comfortable/Wide/Full) in header"
```

Note for Leon: open a note, use the ↔ header menu — Comfortable (720), Wide (960), Full (full-bleed); the choice persists across notes and launches.

---

# Feature B — Full-text search palette

### Task 3: `NoteSearch` match + ranking + snippet (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NoteSearch.swift`
- Test: `Tests/MustardTests/NoteSearchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NoteSearchTests: XCTestCase {
    private func entry(_ path: String, _ title: String, _ content: String) -> NoteSearchEntry {
        NoteSearchEntry(project: "KB", relativePath: path, title: title, content: content)
    }

    func test_empty_query_returns_nothing() {
        let e = [entry("notes/A.md", "Alpha", "body")]
        XCTAssertTrue(NoteSearch.match(entries: e, query: "   ").isEmpty)
    }

    func test_matches_title_filename_and_body_case_insensitively() {
        let e = [
            entry("notes/Alpha.md", "Alpha", "nothing here"),
            entry("notes/B.md", "Bravo", "mentions ALPHA in the body"),
            entry("notes/alpha-notes.md", "Zulu", "unrelated"),
        ]
        let hits = NoteSearch.match(entries: e, query: "alpha")
        XCTAssertEqual(Set(hits.map(\.relativePath)),
                       ["notes/Alpha.md", "notes/B.md", "notes/alpha-notes.md"])
    }

    func test_body_only_hit_carries_snippet_title_hit_does_not() {
        let e = [
            entry("notes/Alpha.md", "Alpha", "irrelevant"),               // title hit
            entry("notes/B.md", "Bravo", "line one\nsecond alpha line"),  // body hit
        ]
        let hits = NoteSearch.match(entries: e, query: "alpha")
        let byPath = Dictionary(uniqueKeysWithValues: hits.map { ($0.relativePath, $0) })
        XCTAssertNil(byPath["notes/Alpha.md"]?.snippet)
        XCTAssertEqual(byPath["notes/B.md"]?.snippet, "second alpha line")
    }

    func test_ranking_title_before_filename_before_body() {
        let e = [
            entry("notes/body.md", "Zeta", "has token inside"),   // body → rank 2
            entry("notes/token.md", "Yankee", "nope"),            // filename → rank 1
            entry("notes/x.md", "token thing", "nope"),           // title → rank 0
        ]
        let hits = NoteSearch.match(entries: e, query: "token")
        XCTAssertEqual(hits.map(\.relativePath),
                       ["notes/x.md", "notes/token.md", "notes/body.md"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NoteSearchTests`
Expected: FAIL — `cannot find 'NoteSearch' / 'NoteSearchEntry' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// SwiftData-free value for one indexable note — mapped from `NoteIndexEntry` at the
/// call site so `match` stays pure/testable.
public struct NoteSearchEntry: Equatable {
    public let project: String
    public let relativePath: String
    public let title: String
    public let content: String
    public init(project: String, relativePath: String, title: String, content: String) {
        self.project = project; self.relativePath = relativePath
        self.title = title; self.content = content
    }
}

public struct NoteSearchHit: Equatable, Identifiable {
    public let project: String
    public let relativePath: String
    public let title: String
    /// First matching body line, only for body-only hits (title/filename hits show the title row already).
    public let snippet: String?
    public var id: String { project + "/" + relativePath }
}

/// Full-text search over the note index (Notes polish pack). Ranks title > filename >
/// body, then alphabetical; body-only hits carry a one-line snippet. Case-insensitive.
public enum NoteSearch {
    public static func match(entries: [NoteSearchEntry], query: String) -> [NoteSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        struct Ranked { let hit: NoteSearchHit; let rank: Int }
        var ranked: [Ranked] = []
        for e in entries {
            let filename = (e.relativePath as NSString).lastPathComponent
            let inTitle = e.title.lowercased().contains(needle)
            let inFilename = filename.lowercased().contains(needle)
            let bodyLine = firstMatchingLine(in: e.content, needle: needle)
            guard inTitle || inFilename || bodyLine != nil else { continue }
            let rank = inTitle ? 0 : (inFilename ? 1 : 2)
            let snippet = (inTitle || inFilename) ? nil : bodyLine
            ranked.append(Ranked(
                hit: NoteSearchHit(project: e.project, relativePath: e.relativePath,
                                   title: e.title, snippet: snippet),
                rank: rank))
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.hit.title.localizedCaseInsensitiveCompare(b.hit.title) == .orderedAscending
        }.map(\.hit)
    }

    private static func firstMatchingLine(in content: String, needle: String) -> String? {
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.lowercased().contains(needle) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NoteSearchTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NoteSearch.swift Tests/MustardTests/NoteSearchTests.swift
git commit -m "feat(notes): NoteSearch full-text match + ranking + snippet (polish pack B)"
```

### Task 4: Search palette view + ⌘⇧F + ⌘K entry (View, build+eye)

**Files:**
- Create: `Sources/MustardKit/Views/NoteSearchView.swift`
- Modify: `Sources/MustardKit/Logic/CommandBarEngine.swift`, `Sources/MustardKit/Views/RootView.swift:53,90-104`

- [ ] **Step 1: Add the `searchNotes` command.** In `CommandBarEngine.swift`, add `case searchNotes` to `CommandKind` (after `.reindexNotes`), and add to the `commands` array:

```swift
        CommandItem(id: "search", title: "Search notes", icon: "magnifyingglass", kind: .searchNotes),
```

- [ ] **Step 2: Create the palette.** `Sources/MustardKit/Views/NoteSearchView.swift`:

```swift
import SwiftUI
import SwiftData

/// Dedicated full-text note search (Notes polish pack). Opened by ⌘⇧F and the ⌘K
/// "Search notes" command. Live results from `NoteSearch`; Enter opens the selection.
/// Presentation mirrors CommandBarView (centered card over a dimmed scrim in RootView).
struct NoteSearchView: View {
    @Binding var isPresented: Bool
    let onOpen: (NoteRef) -> Void
    @Query private var entries: [NoteIndexEntry]
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var sources: [SourceConfig] {
        SourceSettingsStore.loadOrMigrate().sources.filter { $0.enabled && !$0.workingDirectory.isEmpty }
    }
    private var workingDir: [String: String] {
        Dictionary(sources.map { ($0.project, $0.workingDirectory) }, uniquingKeysWith: { a, _ in a })
    }

    private var hits: [NoteSearchHit] {
        NoteSearch.match(
            entries: entries.map {
                NoteSearchEntry(project: $0.project, relativePath: $0.relativePath,
                                title: $0.title, content: $0.contentSnapshot)
            },
            query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textTertiary)
                TextField("Search all notes", text: $query)
                    .textFieldStyle(.plain).font(Theme.Fonts.body)
                    .focused($focused)
                    .onSubmit { open(at: selectedIndex) }
            }
            .padding(12)
            Divider().overlay(Theme.Palette.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                        row(hit, selected: i == selectedIndex)
                            .onTapGesture { open(at: i) }
                    }
                }.padding(8)
            }.frame(maxHeight: 360)
        }
        .frame(width: 520)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onExitCommand { isPresented = false }
    }

    private func row(_ hit: NoteSearchHit, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textPrimary)
            if let snippet = hit.snippet {
                Text(snippet).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
            }
            Text(hit.project).font(.system(size: 10)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.Palette.bg : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func open(at index: Int) {
        let list = hits
        guard list.indices.contains(index), let dir = workingDir[list[index].project] else { return }
        onOpen(NoteRef(project: list[index].project, workingDirectory: dir,
                       relativePath: list[index].relativePath))
        isPresented = false
    }
}
```

*(Keyboard ↑/↓ move `selectedIndex` — wire via `.onMoveCommand(perform:)` on the outer VStack if desired; Enter/click already work. Keep it minimal for the first pass.)*

- [ ] **Step 3: Host it in RootView.** Mirror the `showCommandBar` pattern (`RootView.swift:53,90-104`). Add `@State private var showNoteSearch = false`. In the overlay stack (near line 90), add a second scrim+card for `showNoteSearch` presenting `NoteSearchView(isPresented: $showNoteSearch, onOpen: { ref in /* set screen = .notes and select ref */ })`. Add the shortcut button next to the ⌘K one (line 103):

```swift
                Button("") { showNoteSearch.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .hidden()
```

Route the `.searchNotes` command from `CommandBarView` so selecting "Search notes" sets `showCommandBar = false; showNoteSearch = true`. (Follow how the existing `CommandKind` cases are dispatched in `CommandBarView`/`RootView` — add a `.searchNotes` branch there.)

Opening a result must navigate the Notes surface to that `NoteRef`. If RootView's `screen`/Notes selection can't yet accept an external selection, thread a lightweight selection via an `@Observable` shared object or a binding the Notes surface reads on appear. **Discovery step:** grep `Sources/MustardKit/Views/RootView.swift` and `NotesView.swift` for how `screen` switching works and whether a target `NoteRef` can be handed to `NotesView`; wire the smallest bridge (e.g. an optional `pendingOpen: NoteRef?` the Notes surface consumes). Document the chosen bridge in the commit message.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit + flag for eye-check**

```bash
git add Sources/MustardKit/Views/NoteSearchView.swift Sources/MustardKit/Logic/CommandBarEngine.swift Sources/MustardKit/Views/RootView.swift
git commit -m "feat(notes): dedicated full-text search palette (⌘⇧F + ⌘K)"
```

Note for Leon: ⌘⇧F (or ⌘K → "Search notes") opens a search box; typing matches titles + bodies with snippets; Enter opens the selected note.

---

# Feature C — Wikilink hover preview

### Task 5: `NotePreview.excerpt` (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NotePreview.swift`
- Test: `Tests/MustardTests/NotePreviewTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NotePreviewTests: XCTestCase {
    func test_strips_frontmatter_and_blank_lines_and_honors_maxLines() {
        let content = "---\ntitle: X\ntags: []\n---\n\n# Heading\n\nFirst para.\nSecond para.\nThird para.\n"
        XCTAssertEqual(NotePreview.excerpt(content: content, maxLines: 2), "# Heading\nFirst para.")
    }

    func test_short_note_returns_what_it_has() {
        XCTAssertEqual(NotePreview.excerpt(content: "just one line", maxLines: 4), "just one line")
    }

    func test_empty_content_is_empty() {
        XCTAssertEqual(NotePreview.excerpt(content: "---\ntitle: X\n---\n", maxLines: 3), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotePreviewTests`
Expected: FAIL — `cannot find 'NotePreview' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// First non-empty body lines of a note, for the wikilink hover preview (Notes polish
/// pack). Frontmatter-stripped (reuses the shared `Frontmatter` parser, as
/// BacklinkSnippets/NoteMetadata do). Pure — no view/clock deps.
public enum NotePreview {
    public static func excerpt(content: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let body = Frontmatter.parse(content).body
        var lines: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.count >= maxLines { break }
        }
        return lines.joined(separator: "\n")
    }
}
```

*(If `Frontmatter` is not visible from this file's scope, confirm its access level in `WikilinkIndex.swift` — BacklinkSnippets already calls `Frontmatter.parse(_:).body`, so it is reachable within MustardKit.)*

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotePreviewTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NotePreview.swift Tests/MustardTests/NotePreviewTests.swift
git commit -m "feat(notes): NotePreview hover excerpt (polish pack C)"
```

### Task 6: Hover-preview popover in the editor (View, build+eye)

**Files:**
- Modify: `Sources/MustardKit/Views/MarkdownTextView.swift` (Coordinator — reuse the wikilink range hit-testing that already backs clicks), `Sources/MustardKit/Views/NoteEditorView.swift` (render the popover).

- [ ] **Step 1: Discovery.** In `MarkdownTextView.swift`, find where wikilink click hit-testing happens (grep `onWikilinkTap`, `wikilink`, `mustard-note://`, and `NSString`/`glyphIndex` character-index-from-point). Identify the function that maps a point → the wikilink `target` under it. Hover will reuse the same mapping.

- [ ] **Step 2: Track hover.** Add an `NSTrackingArea` (`.mouseMoved`, `.activeInKeyWindow`) to the text view (in `makeNSView`/on bounds change). In `mouseMoved(with:)`, map the event point → character index → the wikilink `target` under the cursor (via the click hit-test helper). Debounce ~0.4s; publish a small `WikilinkHoverState { target: String; anchor: CGRect; resolved: NoteRef? }` through a binding to `NoteEditorView`, exactly like `slashMenu`/`formatBar` are published (`NoteEditorView.swift:33-37`, coordinator writes `parent.<binding>.wrappedValue`). Clear it on mouse-exit or when the target is nil.

```swift
// In NoteEditorView, alongside slashMenu/formatBar state:
@State private var hoverLink: WikilinkHoverState?
```

Add a `WikilinkHoverState` struct next to `SlashMenuState` in `MarkdownTextView.swift`.

- [ ] **Step 3: Render the popover.** Add a `hoverPreviewOverlay` to `NoteEditorView` mirroring `slashMenuOverlay` (`:173-187`):

```swift
    @ViewBuilder
    private var hoverPreviewOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let hover = hoverLink {
                Group {
                    if let ref = hover.resolved,
                       let entry = entries.first(where: { $0.relativePath == ref.relativePath }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textPrimary)
                            Text(NotePreview.excerpt(content: entry.contentSnapshot, maxLines: 4))
                                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4)
                        }
                    } else {
                        Text("Create note?").font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
                .padding(10)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .offset(x: hover.anchor.minX, y: hover.anchor.maxY + 6)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.pop, value: hoverLink != nil)
    }
```

Resolve `hover.resolved` in the coordinator via the passed-in `resolveWikilink`, so the hover state already knows resolved-vs-dangling. Add `.overlay(alignment: .topLeading) { hoverPreviewOverlay }` next to the existing overlays (`:77-78`), and clear `hoverLink = nil` in the `onChange(of: ref)` block (`:93-97`) so a stale preview never survives a note switch.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit + flag for eye-check**

```bash
git add Sources/MustardKit/Views/MarkdownTextView.swift Sources/MustardKit/Views/NoteEditorView.swift
git commit -m "feat(notes): wikilink hover preview popover"
```

Note for Leon: hover a `[[link]]` — a resolved link peeks the target's title + first lines; a dangling link shows "Create note?".

---

# Feature D — Wikilink autocomplete

### Task 7: `WikilinkAutocomplete` trigger + candidates (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/WikilinkAutocomplete.swift`
- Test: `Tests/MustardTests/WikilinkAutocompleteTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class WikilinkAutocompleteTests: XCTestCase {
    func test_activeQuery_inside_open_link() {
        // "see [[al" caret at end (len 8)
        let q = WikilinkAutocomplete.activeQuery(text: "see [[al", caretUTF16: 8)
        XCTAssertEqual(q?.text, "al")
        XCTAssertEqual(q?.range, NSRange(location: 4, length: 4)) // "[[al"
    }

    func test_nil_when_link_already_closed() {
        // "[[done]] more" caret at end
        XCTAssertNil(WikilinkAutocomplete.activeQuery(text: "[[done]] more", caretUTF16: 13))
    }

    func test_nil_when_newline_between_open_and_caret() {
        XCTAssertNil(WikilinkAutocomplete.activeQuery(text: "[[a\nb", caretUTF16: 5))
    }

    func test_empty_query_right_after_brackets() {
        let q = WikilinkAutocomplete.activeQuery(text: "x [[", caretUTF16: 4)
        XCTAssertEqual(q?.text, "")
    }

    func test_candidates_prefix_before_substring_each_alphabetical() {
        let titles = ["Roadmap", "Beta Roadmap", "Roads", "Alpha"]
        XCTAssertEqual(
            WikilinkAutocomplete.candidates(query: "road", titles: titles),
            ["Roadmap", "Roads", "Beta Roadmap"]) // prefix (A→Z) then substring
    }

    func test_empty_query_returns_all_titles_unchanged() {
        XCTAssertEqual(WikilinkAutocomplete.candidates(query: "", titles: ["B", "A"]), ["B", "A"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WikilinkAutocompleteTests`
Expected: FAIL — `cannot find 'WikilinkAutocomplete' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// `[[` autocomplete for the note editor (Notes polish pack). Detects the open
/// wikilink query at the caret and ranks note-title candidates. Pure; the coordinator
/// drives the popup (mirroring the `/` SlashMenu path) and splices `[[Title]]` through
/// the existing byte-pinned insert path.
public enum WikilinkAutocomplete {
    public struct Query: Equatable {
        /// Covers "[[" + typed text, in UTF-16 coords of the whole document `text`.
        public let range: NSRange
        public let text: String
        public init(range: NSRange, text: String) { self.range = range; self.text = text }
    }

    /// The active `[[…` query at the caret: the nearest "[[" to the left of the caret
    /// on the same line with no intervening "]]" or newline, and no "]" in the query.
    /// nil when the caret is not inside an open, unclosed wikilink.
    public static func activeQuery(text: String, caretUTF16: Int) -> Query? {
        let ns = text as NSString
        guard caretUTF16 >= 2, caretUTF16 <= ns.length else { return nil }
        var i = caretUTF16 - 1
        while i >= 1 {
            let pair = ns.substring(with: NSRange(location: i - 1, length: 2))
            if pair.contains("\n") || pair == "]]" { return nil }
            if pair == "[[" {
                let open = i - 1
                let queryRange = NSRange(location: open + 2, length: caretUTF16 - (open + 2))
                let q = ns.substring(with: queryRange)
                if q.contains("[") || q.contains("]") || q.contains("\n") { return nil }
                return Query(range: NSRange(location: open, length: caretUTF16 - open), text: q)
            }
            i -= 1
        }
        return nil
    }

    /// Titles matching `query`: prefix matches first (case-insensitive), then substring
    /// matches, each group alphabetical. Empty query returns `titles` unchanged.
    public static func candidates(query: String, titles: [String]) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return titles }
        var prefix: [String] = [], substring: [String] = []
        for t in titles {
            let tl = t.lowercased()
            if tl.hasPrefix(needle) { prefix.append(t) }
            else if tl.contains(needle) { substring.append(t) }
        }
        let az: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return prefix.sorted(by: az) + substring.sorted(by: az)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WikilinkAutocompleteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/WikilinkAutocomplete.swift Tests/MustardTests/WikilinkAutocompleteTests.swift
git commit -m "feat(notes): WikilinkAutocomplete trigger + candidates (polish pack D)"
```

### Task 8: Autocomplete popup in the coordinator (View, build+eye)

**Files:**
- Modify: `Sources/MustardKit/Views/MarkdownTextView.swift` (Coordinator: mirror `refreshSlashMenu`/`activeTrigger`/`SlashMenuState` at `:695-825`), `Sources/MustardKit/Views/NoteEditorView.swift` (render the popup + pass note titles + create callback), `Sources/MustardKit/Views/NotesView.swift` (create-on-the-spot callback).

- [ ] **Step 1: Discovery.** Re-read `MarkdownTextView.swift:695-825` — `SlashMenuState`, `refreshSlashMenu(allowOpen:)`, `activeTrigger`, keyboard handling, and the pick→`insertText` splice path (`:794-811`). The autocomplete popup is the same shape with a different trigger and insertion.

- [ ] **Step 2: Add state + candidates source.** Add a `WikilinkAutocompleteState { anchor: CGRect; query: String; selectedIndex: Int }` next to `SlashMenuState`. `NoteEditorView` passes the same-project note **titles** into `MarkdownTextView` (it already receives `entries`); thread `let noteTitles: [String]` into the representable and store on the coordinator's `parent`.

- [ ] **Step 3: Detect + drive.** On text/selection change (where `refreshSlashMenu` is called, `:329`/`:755`), also compute `WikilinkAutocomplete.activeQuery(text:caretUTF16:)` over the full string + caret. When non-nil and `WikilinkAutocomplete.candidates(query:titles:)` is non-empty, publish the autocomplete state (anchored at the caret rect, computed like the slash anchor); otherwise clear it. The `/` menu and `[[` menu are mutually exclusive — if a slash trigger is active, don't also open autocomplete.

- [ ] **Step 4: Insert on pick.** On Enter/click, splice `[[<chosenTitle>]]` by replacing the `Query.range` (the "[["+typed span) through the SAME `insertText(_:replacementRange:)` path the slash menu uses (`:802-811`), inside an undo group. Caret lands after the closing `]]`. A bottom **"Create '<query>'"** row calls a new `onCreateNote: (String) -> Void` callback (threaded from `NoteEditorView` → `NotesView.writeNote`), then inserts `[[<query>]]`.

- [ ] **Step 5: Render.** In `NoteEditorView`, add a `wikilinkAutocompleteOverlay` mirroring `slashMenuOverlay` (`:173-187`), rendering a compact list of `candidates` + the trailing "Create '<query>'" row, positioned at the published anchor.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 7: Commit + flag for eye-check**

```bash
git add Sources/MustardKit/Views/MarkdownTextView.swift Sources/MustardKit/Views/NoteEditorView.swift Sources/MustardKit/Views/NotesView.swift
git commit -m "feat(notes): [[ wikilink autocomplete popup with create-on-the-spot"
```

Note for Leon: type `[[` in a note — a title picker appears; keep typing to filter; Enter inserts `[[Title]]`; the "Create …" row makes a new note and links it.

---

# Feature E — Note rename / delete

### Task 9: `NoteVaultIO.move` + `trash` (IO, TDD)

**Files:**
- Modify: `Sources/MustardKit/Agent/FileVaultIO.swift:84-114`
- Test: `Tests/MustardTests/FileVaultIOMutationTests.swift`

- [ ] **Step 1: Write the failing test** (real temp-dir IO, the boundary-test pattern):

```swift
import XCTest
@testable import MustardKit

final class FileVaultIOMutationTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_move_relocates_file() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let io = FileVaultIO(root: root)
        try io.write("notes/Old.md", "# Old\n")
        try io.move(from: "notes/Old.md", to: "notes/New.md")
        XCTAssertNil(io.read("notes/Old.md"))
        XCTAssertEqual(io.read("notes/New.md"), "# Old\n")
    }

    func test_trash_removes_from_vault() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let io = FileVaultIO(root: root)
        try io.write("notes/Doomed.md", "bye\n")
        try io.trash("notes/Doomed.md")
        XCTAssertNil(io.read("notes/Doomed.md"))
        XCTAssertFalse(io.notePaths().contains("notes/Doomed.md"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileVaultIOMutationTests`
Expected: FAIL — `value of type 'FileVaultIO' has no member 'move'`.

- [ ] **Step 3: Implement.** Add to the `NoteVaultIO` protocol (`:84-90`):

```swift
    func move(from: String, to: String) throws
    func trash(_ relativePath: String) throws
```

Add to the `extension FileVaultIO: NoteVaultIO` (`:92-114`):

```swift
    public func move(from: String, to: String) throws {
        let src = root.appendingPathComponent(from)
        let dst = root.appendingPathComponent(to)
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.moveItem(at: src, to: dst)
    }

    /// System Trash (Finder-recoverable) — Mustard isn't git-backed yet, so this is
    /// the reversible delete (spec: no hard delete in this slice).
    public func trash(_ relativePath: String) throws {
        try fileManager.trashItem(at: root.appendingPathComponent(relativePath),
                                  resultingItemURL: nil)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileVaultIOMutationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Agent/FileVaultIO.swift Tests/MustardTests/FileVaultIOMutationTests.swift
git commit -m "feat(notes): NoteVaultIO.move + trash (polish pack E)"
```

### Task 10: `NoteRename` link-aware plan (Logic, TDD)

**Files:**
- Modify: `Sources/MustardKit/Logic/NoteCreation.swift` (expose two helpers)
- Create: `Sources/MustardKit/Logic/NoteRename.swift`
- Test: `Tests/MustardTests/NoteRenameTests.swift`

- [ ] **Step 1: Expose NoteCreation helpers (DRY).** In `NoteCreation.swift`, change `normalizedTitle` and `yamlValue` from `private` to `public`, renamed for a clear public surface:

```swift
    /// Trimmed, newline-folded display name (falls back to "Untitled"). Public so
    /// NoteRename can retitle a note's frontmatter/heading with identical rules.
    public static func displayName(_ title: String) -> String { /* body of normalizedTitle */ }

    /// YAML-safe rendering of a title value (quotes only when a real parser needs it).
    public static func yamlEscaped(_ title: String) -> String { /* body of yamlValue */ }
```

Update the two internal call sites (`sanitizedName`, `stub`) to the new names. (Existing `NoteCreationTests` still pass unchanged — behavior is identical.)

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NoteRenameTests: XCTestCase {
    private let resolveToOld: (String) -> String? = { target in
        // Old note lives at notes/Old.md; links by "Old" (or alias) resolve to it.
        target.caseInsensitiveCompare("Old") == .orderedSame ? "notes/Old.md" : nil
    }

    func test_rewrite_plain_heading_alias_and_embed_forms() {
        let content = """
        plain [[Old]] mid
        heading [[Old#Section]] end
        alias [[Old|see this]] end
        embed ![[Old]] end
        untouched [[Other]] end
        """
        let out = NoteRename.rewrite(content: content, resolve: resolveToOld,
                                     oldPath: "notes/Old.md", newTarget: "New")
        XCTAssertTrue(out.contains("[[New]] mid"))
        XCTAssertTrue(out.contains("[[New#Section]] end"))
        XCTAssertTrue(out.contains("[[New|see this]] end"))
        XCTAssertTrue(out.contains("![[New]] end"))
        XCTAssertTrue(out.contains("[[Other]] end"))
    }

    func test_rewrite_skips_fenced_code() {
        let content = "real [[Old]]\n```\ncode [[Old]] stays\n```\n"
        let out = NoteRename.rewrite(content: content, resolve: resolveToOld,
                                     oldPath: "notes/Old.md", newTarget: "New")
        XCTAssertTrue(out.contains("real [[New]]"))
        XCTAssertTrue(out.contains("code [[Old]] stays"))
    }

    func test_retitle_updates_frontmatter_title_and_first_heading() {
        let content = "---\ntitle: Old\ntags: []\n---\n\n# Old\n\nbody [[keep]]\n"
        let out = NoteRename.retitle(content: content, newTitle: "Fresh Name")
        XCTAssertTrue(out.contains("title: Fresh Name"))
        XCTAssertTrue(out.contains("# Fresh Name"))
        XCTAssertTrue(out.contains("body [[keep]]"))
    }

    func test_plan_composes_newpath_retitle_and_linkedits() {
        let others = [
            (relativePath: "notes/Ref.md", content: "see [[Old]] here"),
            (relativePath: "notes/None.md", content: "no links"),
        ]
        let plan = NoteRename.plan(
            oldRelativePath: "notes/Old.md",
            oldContent: "---\ntitle: Old\n---\n\n# Old\n",
            newTitle: "New",
            others: others,
            existingPaths: ["notes/Ref.md", "notes/None.md"]) // old path excluded by caller
        XCTAssertEqual(plan.newRelativePath, "notes/New.md")
        XCTAssertTrue(plan.renamedNoteContent.contains("title: New"))
        XCTAssertEqual(plan.linkEdits.map(\.relativePath), ["notes/Ref.md"]) // only the note that changed
        XCTAssertTrue(plan.linkEdits.first!.newContent.contains("[[New]]"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter NoteRenameTests`
Expected: FAIL — `cannot find 'NoteRename' in scope`.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Link-aware note rename (Notes polish pack). Pure planning: computes the new path
/// (NoteCreation collision rules), retitles the renamed note's own frontmatter/heading,
/// and rewrites inbound `[[links]]` across other notes. Reuses THE shared wikilink
/// regex (`WikilinkSyntax`) so every link form is covered; skips fenced code, as the
/// index does. Execution (move/write/reindex) lives in NotesView.
public enum NoteRename {
    public struct LinkEdit: Equatable {
        public let relativePath: String
        public let newContent: String
    }
    public struct Plan: Equatable {
        public let oldRelativePath: String
        public let newRelativePath: String
        public let renamedNoteContent: String
        public let linkEdits: [LinkEdit]
    }

    public static func plan(oldRelativePath: String, oldContent: String, newTitle: String,
                            others: [(relativePath: String, content: String)],
                            existingPaths: [String]) -> Plan {
        let newRelativePath = NoteCreation.relativePath(title: newTitle, existing: existingPaths)
        let newTarget = NoteCreation.displayName(newTitle)
        // Resolver over the CURRENT path set (old path + others) identifies inbound links.
        let allPaths = [oldRelativePath] + others.map(\.relativePath)
        let resolve = WikilinkIndex.resolver(paths: allPaths)
        var edits: [LinkEdit] = []
        for note in others {
            let rewritten = rewrite(content: note.content, resolve: resolve,
                                    oldPath: oldRelativePath, newTarget: newTarget)
            if rewritten != note.content {
                edits.append(LinkEdit(relativePath: note.relativePath, newContent: rewritten))
            }
        }
        return Plan(oldRelativePath: oldRelativePath, newRelativePath: newRelativePath,
                    renamedNoteContent: retitle(content: oldContent, newTitle: newTitle),
                    linkEdits: edits)
    }

    /// Updates the renamed note's own frontmatter `title:` and first ATX heading.
    public static func retitle(content: String, newTitle: String) -> String {
        let name = NoteCreation.displayName(newTitle)
        var lines = content.components(separatedBy: "\n")
        if lines.first == "---" {
            var i = 1
            while i < lines.count, lines[i] != "---" {
                if lines[i].hasPrefix("title:") { lines[i] = "title: \(NoteCreation.yamlEscaped(name))"; break }
                i += 1
            }
        }
        for i in lines.indices {
            if let hashes = atxHeadingPrefix(lines[i]) { lines[i] = "\(hashes) \(name)"; break }
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrites wikilink occurrences whose target resolves to `oldPath`, swapping only
    /// the target segment (bang / `#heading` / `|alias` preserved). Skips fenced code.
    public static func rewrite(content: String, resolve: (String) -> String?,
                               oldPath: String, newTarget: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in content.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle(); out.append(raw); continue
            }
            out.append(inFence ? raw : rewriteLine(raw, resolve: resolve, oldPath: oldPath, newTarget: newTarget))
        }
        return out.joined(separator: "\n")
    }

    private static func rewriteLine(_ line: String, resolve: (String) -> String?,
                                    oldPath: String, newTarget: String) -> String {
        let ns = line as NSString
        let matches = WikilinkSyntax.regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        var result = line
        for match in matches.reversed() {   // right-to-left keeps leftward ranges valid
            let targetRange = match.range(at: 1)
            guard targetRange.location != NSNotFound else { continue }
            let target = ns.substring(with: targetRange).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, resolve(target) == oldPath else { continue }
            let full = ns.substring(with: match.range)
            let bang = full.hasPrefix("!") ? "!" : ""
            let hRange = match.range(at: 2)
            let heading = hRange.location == NSNotFound ? "" : ns.substring(with: hRange)
            let aRange = match.range(at: 4)
            let alias = aRange.location == NSNotFound ? "" : "|" + ns.substring(with: aRange)
            let replacement = "\(bang)[[\(newTarget)\(heading)\(alias)]]"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func atxHeadingPrefix(_ line: String) -> String? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        guard (1...6).contains(count) else { return nil }
        let after = line.index(line.startIndex, offsetBy: count)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(repeating: "#", count: count)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter NoteRenameTests`
Expected: PASS. Then run `swift test --filter NoteCreationTests` to confirm the helper rename didn't regress creation.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Logic/NoteRename.swift Sources/MustardKit/Logic/NoteCreation.swift Tests/MustardTests/NoteRenameTests.swift
git commit -m "feat(notes): NoteRename link-aware plan (retitle + rewrite) (polish pack E)"
```

### Task 11: Sidebar rename/delete context menu + execution (View, build+eye)

**Files:**
- Modify: `Sources/MustardKit/Views/NotesView.swift` (`leafRow` `:171-195`, plus execution helpers near `writeNote` `:236-254`).

- [ ] **Step 1: Add the context menu.** On the `leafRow` button (`:175-193`), add:

```swift
        .contextMenu {
            Button("Rename…") { renaming = RenameTarget(ref: ref, currentTitle: leaf.title) }
            Button("Delete…", role: .destructive) { deleting = DeleteTarget(ref: ref, title: leaf.title) }
        }
```

Add `@State private var renaming: RenameTarget?` and `@State private var deleting: DeleteTarget?` plus small `Identifiable` structs (mirror `CreateTarget` `:35-38`). Present a rename sheet (reuse `NewNoteSheet`'s shape with the title prefilled) and a delete `.confirmationDialog`.

- [ ] **Step 2: Delete execution.**

```swift
    private func performDelete(_ target: DeleteTarget) {
        let io = FileVaultIO(rootPath: target.ref.workingDirectory)
        try? io.trash(target.ref.relativePath)
        noteIndex.reindex(project: target.ref.project, workingDirectory: target.ref.workingDirectory)
        if selected == target.ref { selected = nil }
        deleting = nil
    }
```

- [ ] **Step 3: Rename execution.** Gather same-project entries as `(relativePath, contentSnapshot)`, build the plan, apply it (snapshot-before-write for each touched file, mirroring `NoteEditorView.save` `:256-270`):

```swift
    private func performRename(_ target: RenameTarget, newTitle: String) {
        let io = FileVaultIO(rootPath: target.ref.workingDirectory)
        guard let oldContent = io.read(target.ref.relativePath) else { renaming = nil; return }
        let projectEntries = entries.filter { $0.project == target.ref.project }
        let others = projectEntries
            .filter { $0.relativePath != target.ref.relativePath }
            .map { (relativePath: $0.relativePath, content: $0.contentSnapshot) }
        let existing = projectEntries
            .map(\.relativePath)
            .filter { $0 != target.ref.relativePath }   // exclude self so a re-title of the same note doesn't collide-suffix
        let plan = NoteRename.plan(oldRelativePath: target.ref.relativePath,
                                   oldContent: oldContent, newTitle: newTitle,
                                   others: others, existingPaths: existing)
        do {
            try io.snapshot(target.ref.relativePath, oldContent)
            if plan.newRelativePath != plan.oldRelativePath {
                try io.move(from: plan.oldRelativePath, to: plan.newRelativePath)
            }
            try io.write(plan.newRelativePath, plan.renamedNoteContent)
            for edit in plan.linkEdits {
                if let prior = io.read(edit.relativePath) { try io.snapshot(edit.relativePath, prior) }
                try io.write(edit.relativePath, edit.newContent)
            }
        } catch { renaming = nil; return }   // partial failure leaves snapshots; note stays put
        noteIndex.reindex(project: target.ref.project, workingDirectory: target.ref.workingDirectory)
        selected = NoteRef(project: target.ref.project,
                           workingDirectory: target.ref.workingDirectory,
                           relativePath: plan.newRelativePath)
        renaming = nil
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit + flag for eye-check**

```bash
git add Sources/MustardKit/Views/NotesView.swift
git commit -m "feat(notes): sidebar rename (link-aware) + delete-to-Trash context menu"
```

Note for Leon: right-click a note in the sidebar → Rename… (updates its title/heading AND rewrites every `[[link]]` pointing to it) or Delete… (moves the file to Trash; recoverable in Finder).

---

## Final verification

- [ ] Run the whole suite: `swift test` — all green (new suites: NoteEditorWidth, NoteSearch, NotePreview, WikilinkAutocomplete, FileVaultIOMutation, NoteRename; plus unchanged NoteCreationTests).
- [ ] `swift build` succeeds.
- [ ] `./build-app.sh` produces a runnable `build/Mustard.app` for Leon's eye-check of all five surfaces.
- [ ] Update `docs/build-order.md` if it tracks Notes features (append the polish pack as shipped).

## Out of scope (do not build here)

Neighborhood / typed relationships / graph (slice 2); rich rendering (code highlighting, LaTeX, image thumbnails); git version history; iOS view wiring (logic is shared and ready); fuzzy search scoring; move-between-folders drag; tag browsing.
