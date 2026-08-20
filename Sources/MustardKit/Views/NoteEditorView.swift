import SwiftUI

/// Craft-style live note editor for the Notes surface (spec 2026-07-06, Phase 2a):
/// a document header (derived title + quiet metadata line) over a single
/// always-rendered, editable MarkdownTextView — no Source/Preview toggle. The text
/// view's string stays byte-identical to the note on disk; styling is attributes,
/// never rewrites.
///
/// `onNavigate` routes backlink-row taps back through NotesView selection (so the
/// editor's save-on-switch fires). `resolveWikilink`/`onWikilinkTap` wire the
/// editor's `[[wikilinks]]` — the former colours resolved vs dangling links, the
/// latter navigates on click (or offers create-from-unresolved in the host).
struct NoteEditorView: View {
    let ref: NoteRef
    /// Same-project index entries, passed by NotesView — the backlinks panel reads
    /// these (which notes link here) rather than @Querying independently.
    let entries: [NoteIndexEntry]
    let onNavigate: (NoteRef) -> Void
    /// Resolves a wikilink target to a same-project note (nil when it dangles) —
    /// drives the editor's link colour. Built once per NotesView body evaluation.
    let resolveWikilink: (String) -> NoteRef?
    /// Handles a wikilink click: navigate to the target, or offer to create it
    /// when unresolved. NotesView owns the decision.
    let onWikilinkTap: (String) -> Void
    /// Creates a note by title WITHOUT navigating (autocomplete's Create row —
    /// the caret must stay put mid-typing). NotesView's writeNote, threaded
    /// through; returns the created relativePath so the link targets ITS stem.
    var onCreateNote: (String) -> String? = { _ in nil }
    @Environment(NoteIndexService.self) private var noteIndex
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var diskText = ""      // content at load — the dirty-check baseline
    @State private var loadFailed = false
    /// The note that `text` / `diskText` currently belong to. Nil while a
    /// reload is in flight (the one-runloop gap after `onChange(of: ref)`
    /// and before `.task` finishes) so ⌘S cannot persist the old buffer
    /// over the new file.
    @State private var contentRef: NoteRef?
    /// Disk mtime for the metadata line — restatted on load / successful
    /// save of the on-screen note, never on every body evaluation.
    @State private var cachedModified: Date?
    /// Slash-menu presentation (2b): written by the text view's coordinator via
    /// the binding, rendered here as a caret-anchored overlay.
    @State private var slashMenu: SlashMenuState?
    /// Floating format-toolbar presentation (Phase 4 / BAK-253): same pattern
    /// as `slashMenu` — the coordinator writes it on selection change, this
    /// view renders the overlay.
    @State private var formatBar: InlineFormatBarState?
    /// Wikilink hover-preview presentation (polish pack C): same pattern.
    @State private var hoverLink: WikilinkHoverState?
    /// `[[` autocomplete presentation (polish pack D): same pattern.
    @State private var autocomplete: WikilinkAutocompleteState?
    /// Moveable-block geometry from the layout manager — drives the hover gutter.
    @State private var blockRects: [MarkdownBlockRect] = []
    /// Imperative bridge overlay clicks/drags use to reach the coordinator.
    @State private var editorProxy = MarkdownEditorProxy()

    /// Reading-measure setting (Notes polish pack A) — global, persisted; replaces
    /// the old fixed 720pt measure. `NoteEditorWidth` owns the pt values.
    @AppStorage("noteEditorWidth") private var widthRaw = NoteEditorWidth.comfortable.rawValue
    private var editorWidth: NoteEditorWidth { NoteEditorWidth(rawValue: widthRaw) ?? .comfortable }

    private var isDirty: Bool { text != diskText }

    /// Autocomplete candidates: display title + the filename stem links resolve by.
    private var linkCandidates: [WikilinkAutocomplete.LinkCandidate] {
        entries.map {
            WikilinkAutocomplete.LinkCandidate(
                title: $0.title, stem: WikilinkAutocomplete.stem(ofPath: $0.relativePath))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if loadFailed {
                missingState
            } else {
                MarkdownTextView(
                    text: $text,
                    resolveWikilink: resolveWikilink,
                    onWikilinkTap: onWikilinkTap,
                    slashMenu: $slashMenu,
                    formatBar: $formatBar,
                    hoverLink: $hoverLink,
                    autocomplete: $autocomplete,
                    noteCandidates: linkCandidates,
                    onCreateNote: onCreateNote,
                    onBlockRectsChange: { blockRects = $0 },
                    proxy: editorProxy
                )
                // Hover gutter under the menu: ⠿ drag-reorder + per-block insert.
                .overlay(alignment: .topLeading) {
                    BlockGutterOverlay(
                        rects: blockRects,
                        onMove: { from, to in editorProxy.moveBlock(from: from, to: to) },
                        onInsert: { editorProxy.openSlashMenu(atBlock: $0) },
                        onTurnInto: { index, target in editorProxy.turnIntoBlock(index, target: target) },
                        onDuplicate: { editorProxy.duplicateBlock($0) },
                        onDelete: { editorProxy.deleteBlock($0) },
                        onMoveUp: { editorProxy.moveBlockUp($0) },
                        onMoveDown: { editorProxy.moveBlockDown($0) }
                    )
                }
                .overlay(alignment: .topLeading) { slashMenuOverlay }
                .overlay(alignment: .topLeading) { formatBarOverlay }
                .overlay(alignment: .topLeading) { autocompleteOverlay }
                .overlay(alignment: .topLeading) { hoverPreviewOverlay }
                // Keep the editor's overlays (menu near the bottom edge) above
                // the later BacklinksPanel sibling, which would otherwise draw
                // over them.
                .zIndex(1)
                BacklinksPanel(current: ref, entries: entries, onNavigate: onNavigate)
            }
        }
        .frame(maxWidth: editorWidth.maxWidth ?? .infinity)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bg)
        // Save the OLD note before the ref-keyed .task reloads: onChange(old,new)
        // fires while state still holds the old note's text, so we can flush edits
        // that would otherwise be dropped when switching notes.
        .onChange(of: ref) { oldRef, _ in
            save(to: oldRef, content: text, ifDifferentFrom: diskText)
            contentRef = nil       // buffer is in-flight; refuse ⌘S until .task reloads
            cachedModified = nil   // restat belongs to the incoming note
            slashMenu = nil    // a half-typed trigger must not survive a note switch
            formatBar = nil    // a stale selection toolbar must not survive a note switch
            hoverLink = nil    // a preview of the OLD note's link must not survive either
            autocomplete = nil // nor a half-typed [[ query
        }
        // Autosave when the editor leaves the hierarchy — switching away from the
        // Notes tab or closing the detail pane tears the view down without firing
        // onChange(of: ref), which would otherwise drop dirty edits silently.
        .onDisappear {
            save(to: ref, content: text, ifDifferentFrom: diskText)
        }
        // Best-effort flush on app quit / hide: onDisappear isn't guaranteed to run
        // at termination. The dirty gate makes a redundant save a cheap no-op.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                save(to: ref, content: text, ifDifferentFrom: diskText)
            }
        }
        .task(id: ref) {
            let io = FileVaultIO(rootPath: ref.workingDirectory)
            if let loaded = io.read(ref.relativePath) {
                text = loaded
                diskText = loaded
                loadFailed = false
                cachedModified = io.modificationDate(ref.relativePath)
            } else {
                text = ""
                diskText = ""
                loadFailed = true
                cachedModified = nil
            }
            contentRef = ref
        }
    }

    // MARK: - Document header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(noteTitle)
                    .font(Theme.Fonts.docTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)

                if isDirty {
                    Circle()
                        .fill(Theme.Palette.warning)
                        .frame(width: 6, height: 6)
                }

                Spacer(minLength: 12)

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

                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty || contentRef != ref)
            }

            Text(metadataLine)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    /// "project · edited today · 214 words" — the ambient clock/zone is fine in
    /// the VIEW; only NoteMetadata's tests pin time. Word count stays live
    /// (it's a string walk of @State `text`); the file stat is the cached
    /// mtime filled by `.task(id: ref)` / a successful save, not a per-
    /// keystroke syscall.
    private var metadataLine: String {
        NoteMetadata.line(
            project: ref.project,
            modified: cachedModified,
            wordCount: NoteMetadata.wordCount(text),
            now: .now,
            calendar: .current
        )
    }

    /// The caret-anchored slash menu, positioned by the coordinator-published
    /// anchor (already in this overlay's coordinate space). Appear/disappear with
    /// `Theme.Motion.pop`; keyboard selection lives in the coordinator, clicks
    /// route back through the proxy.
    @ViewBuilder
    private var slashMenuOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let menu = slashMenu {
                SlashMenuView(
                    query: menu.query,
                    selectedIndex: menu.selectedIndex,
                    onPick: { editorProxy.pick($0) }
                )
                .offset(x: menu.anchor.minX, y: menu.anchor.maxY + 6)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
        .animation(Theme.Motion.pop, value: slashMenu != nil)
    }

    /// The selection-anchored format toolbar (Phase 4 / BAK-253), positioned
    /// by the coordinator-published anchor (already in this overlay's
    /// coordinate space) just ABOVE the selection's start — the toolbar reads
    /// above the text it's about to format rather than covering it, mirroring
    /// where Craft/most editors place this affordance. Same appear/disappear
    /// motion and overlay pattern as `slashMenuOverlay`.
    @ViewBuilder
    private var formatBarOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let bar = formatBar {
                InlineFormatBarView(onToggle: { editorProxy.toggleInlineFormat($0) })
                    .offset(x: bar.anchor.minX, y: bar.anchor.minY - 40)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
        .animation(Theme.Motion.pop, value: formatBar != nil)
    }

    /// The caret-anchored `[[` title picker (polish pack D), positioned like the
    /// slash menu; keyboard selection lives in the coordinator, clicks route back
    /// through the proxy's undo-safe splice.
    @ViewBuilder
    private var autocompleteOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let menu = autocomplete {
                WikilinkAutocompleteView(
                    query: menu.query,
                    selectedIndex: menu.selectedIndex,
                    candidates: linkCandidates,
                    onPick: { editorProxy.pickWikilink($0) },
                    onCreate: { editorProxy.createWikilinkNote($0) }
                )
                .offset(x: menu.anchor.minX, y: menu.anchor.maxY + 6)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
        .animation(Theme.Motion.pop, value: autocomplete != nil)
    }

    /// The hovered-wikilink peek (polish pack C): a resolved target shows its
    /// title + first body lines from the index's contentSnapshot; a dangling one
    /// shows a quiet create hint. Draw-only — clicks still belong to the editor.
    @ViewBuilder
    private var hoverPreviewOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let hover = hoverLink {
                Group {
                    if let target = hover.resolved,
                       let entry = entries.first(where: { $0.relativePath == target.relativePath }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(Theme.Fonts.body.weight(.medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                            Text(NotePreview.excerpt(content: entry.contentSnapshot, maxLines: 4))
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4)
                        }
                    } else {
                        Text("Unresolved — click to create “\(hover.target)”")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: 320, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.rLg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.rLg)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
                .offset(x: hover.anchor.minX, y: hover.anchor.maxY + 6)
                .transition(.opacity)
                .allowsHitTesting(false)   // never intercept the click that follows a hover
            }
        }
        .animation(Theme.Motion.pop, value: hoverLink != nil)
    }

    private var missingState: some View {
        VStack {
            Spacer()
            Text("This note is missing from disk.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Title derivation

    /// frontmatter title → first `#{1,6} ` heading → filename stem. Recomputed per
    /// keystroke (text is @State, read by the header), so it parses frontmatter ONCE
    /// and scans lines directly rather than running the full block parser.
    private var noteTitle: String {
        let parsed = Frontmatter.parse(text)
        if let fmTitle = parsed.title, !fmTitle.isEmpty {
            return fmTitle
        }
        if let heading = firstHeading(parsed.body) {
            return heading
        }
        return ((ref.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Cheap early-exit scan for the first `#{1,6} ` line. Deliberately does NOT
    /// skip code fences — a fenced `# comment` before any real heading is a
    /// vanishingly rare title position, not worth a full parse per keystroke.
    private func firstHeading(_ body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard hashes >= 1, hashes <= 6 else { continue }
            let rest = trimmed.dropFirst(hashes)
            guard rest.hasPrefix(" ") else { continue }
            let title = rest.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    // MARK: - Save

    private func save() {
        save(to: ref, content: text, ifDifferentFrom: diskText)
    }

    /// Snapshot-before-save (spec addendum #5), then write and reindex. The dirty
    /// gate + baseline-advance rule are decided by `NoteSaveFlow` (pure, unit-tested);
    /// this method owns only the IO those decisions drive.
    private func save(to ref: NoteRef, content: String, ifDifferentFrom baseline: String) {
        let plan = NoteSaveFlow.plan(content: content, baseline: baseline,
                                     savedRef: ref, currentRef: self.ref,
                                     contentRef: contentRef)
        guard plan.shouldWrite else { return }
        let io = FileVaultIO(rootPath: ref.workingDirectory)
        // Snapshot is belt-and-braces — a failed snapshot must not block the save.
        if let prior = io.read(ref.relativePath) { try? io.snapshot(ref.relativePath, prior) }
        // Failed write must stay dirty — the dot is the only honesty signal.
        do { try io.write(ref.relativePath, content) } catch { return }
        if plan.shouldAdvanceBaseline {
            diskText = content
            cachedModified = io.modificationDate(ref.relativePath)
        }
        noteIndex.reindex(project: ref.project, workingDirectory: ref.workingDirectory)
    }
}
