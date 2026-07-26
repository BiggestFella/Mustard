import SwiftUI
import SwiftData

/// Identity of one note on disk — the selection currency for the Notes surface.
public struct NoteRef: Equatable, Hashable {
    public let project: String
    public let workingDirectory: String
    public let relativePath: String
    public init(project: String, workingDirectory: String, relativePath: String) {
        self.project = project
        self.workingDirectory = workingDirectory
        self.relativePath = relativePath
    }
}

/// The Notes surface (BAK-149): a project-grouped folder-tree sidebar with a
/// filename/title filter, and a placeholder detail pane (the editor is Task 6).
public struct NotesView: View {
    @Query private var entries: [NoteIndexEntry]
    @Environment(NoteIndexService.self) private var noteIndex
    @State private var selected: NoteRef?
    @State private var filter = ""
    @State private var expanded: Set<String> = []
    @State private var creating: CreateTarget?
    @State private var newNoteTitle = ""
    @State private var renaming: RenameTarget?
    @State private var renameTitle = ""
    @State private var deleting: DeleteTarget?
    /// An unresolved wikilink target the user tapped — drives the create-from-link
    /// offer (Task 9). Non-nil presents the alert; the target is created in the
    /// currently-open note's project.
    @State private var pendingWikilinkTarget: String?
    /// A note handed in from outside (the ⌘⇧F search palette) for this surface to
    /// select — consumed then cleared, mirroring RootView's notch-task handoff.
    @Binding private var pendingOpen: NoteRef?

    public init(pendingOpen: Binding<NoteRef?> = .constant(nil)) {
        self._pendingOpen = pendingOpen
    }

    /// The project the create sheet is currently targeting. `SourceConfig` isn't
    /// Identifiable, so key `.sheet(item:)` by the project string.
    private struct CreateTarget: Identifiable {
        let config: SourceConfig
        var id: String { config.project }
    }

    /// The note the rename sheet is targeting (polish pack E).
    private struct RenameTarget: Identifiable {
        let ref: NoteRef
        let currentTitle: String
        var id: String { ref.project + "/" + ref.relativePath }
    }

    /// The note the delete confirmation is targeting (polish pack E).
    private struct DeleteTarget: Identifiable {
        let ref: NoteRef
        let title: String
        var id: String { ref.project + "/" + ref.relativePath }
    }

    /// Enabled sources with a real working directory — the projects we can browse.
    private var sources: [SourceConfig] {
        SourceSettingsStore.loadOrMigrate().sources
            .filter { $0.enabled && !$0.workingDirectory.isEmpty }
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
                .background(Theme.Palette.sidebar)
            Divider().overlay(Theme.Palette.hairline)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $creating) { target in
            createNoteSheet(target)
        }
        .sheet(item: $renaming) { target in
            // Reuses the NewNoteSheet shape with the current title prefilled —
            // return commits, Escape cancels, same calm prompt (polish pack E).
            NewNoteSheet(heading: "Rename “\(target.currentTitle)”",
                         confirmLabel: "Rename", title: $renameTitle,
                         onCancel: { renaming = nil },
                         onCreate: { performRename(target, newTitle: renameTitle) })
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { target in
            Button("Move to Trash", role: .destructive) { performDelete(target) }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("The file moves to the system Trash — recoverable in Finder. Links pointing at it will dangle.")
        }
        // Consume a search-palette selection: setting `selected` flushes any open
        // note's save-on-switch, same as sidebar navigation. `initial: true` covers
        // the handoff landing before this surface is on screen (⌘⇧F from another tab).
        .onChange(of: pendingOpen, initial: true) { _, ref in
            guard let ref else { return }
            selected = ref
            pendingOpen = nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterField
            Divider().overlay(Theme.Palette.hairline)
            if sources.isEmpty {
                emptyState("Add a project in Agent → Sources to browse notes.",
                           symbol: "folder.badge.plus")
            } else if entries.isEmpty {
                emptyState("No notes indexed yet — ⌘K → Reindex notes now.",
                           symbol: "doc.text.magnifyingglass")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sources, id: \.project) { source in
                            projectSection(source)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Filter notes", text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .padding(12)
    }

    @ViewBuilder
    private func projectSection(_ source: SourceConfig) -> some View {
        let leaves: [(relativePath: String, title: String)] = entries
            .filter { $0.project == source.project }
            .map { ($0.relativePath, $0.title) }
        let tree = NoteTree.filter(NoteTree.build(leaves), query: filter)

        HStack(spacing: 4) {
            Text(source.project)
                .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: 0)
            Button {
                newNoteTitle = ""
                creating = CreateTarget(config: source)
            } label: {
                Image(systemName: "plus")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("New note in \(source.project)")
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 4)

        folderContents(tree, source: source, depth: 0)
    }

    /// Renders a folder's notes and subfolders (the root folder's own row is not
    /// drawn — its children hang directly under the project header). Returns
    /// `AnyView` to break the folder/leaf mutual recursion, which otherwise makes
    /// the opaque return type reference itself.
    private func folderContents(_ folder: NoteTreeFolder, source: SourceConfig, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folder.subfolders) { sub in
                    folderRow(sub, source: source, depth: depth)
                }
                ForEach(folder.notes) { leaf in
                    leafRow(leaf, source: source, depth: depth)
                }
            }
        )
    }

    private func folderRow(_ folder: NoteTreeFolder, source: SourceConfig, depth: Int) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: folder, in: source)) {
            folderContents(folder, source: source, depth: depth + 1)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(Theme.Fonts.meta)
                    .frame(width: 16)
                Text(folder.name)
                    .font(Theme.Fonts.body)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .contentShape(Rectangle())
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func leafRow(_ leaf: NoteTreeLeaf, source: SourceConfig, depth: Int) -> some View {
        let ref = NoteRef(project: source.project, workingDirectory: source.workingDirectory,
                          relativePath: leaf.relativePath)
        let isSelected = selected == ref
        return Button {
            selected = ref
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(Theme.Fonts.meta)
                    .frame(width: 16)
                Text(leaf.title)
                    .font(Theme.Fonts.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .contextMenu {
            Button("Rename…") {
                renameTitle = leaf.title
                renaming = RenameTarget(ref: ref, currentTitle: leaf.title)
            }
            Button("Delete…", role: .destructive) {
                deleting = DeleteTarget(ref: ref, title: leaf.title)
            }
        }
    }

    /// While a filter query is active, folders are force-expanded (matches are only
    /// useful visible); with no filter they collapse to a calm resting state.
    /// Expansion state is keyed by project-qualified path — `folder.path` is
    /// project-relative, so two projects both containing e.g. `guides/` must not
    /// share one expansion bit.
    private func expansionBinding(for folder: NoteTreeFolder, in source: SourceConfig) -> Binding<Bool> {
        let key = "\(source.project)/\(folder.path)"
        let filtering = NoteTree.isActiveQuery(filter)
        return Binding(
            get: { filtering || expanded.contains(key) },
            set: { newValue in
                if newValue { expanded.insert(key) } else { expanded.remove(key) }
            }
        )
    }

    // MARK: - New note ("+" — BAK-153)

    /// A calm title prompt. An empty title is allowed — it falls back to "Untitled"
    /// via `NoteCreation` (filename and stub heading agree), so Create is never
    /// disabled.
    @ViewBuilder
    private func createNoteSheet(_ target: CreateTarget) -> some View {
        NewNoteSheet(heading: "New note in \(target.config.project)", title: $newNoteTitle,
                     onCancel: { creating = nil },
                     onCreate: { create(in: target) })
    }

    private func create(in target: CreateTarget) {
        createNote(title: newNoteTitle, project: target.config.project,
                   workingDirectory: target.config.workingDirectory)
        newNoteTitle = ""
        creating = nil
    }

    /// Shared write→reindex→select primitive for both the "+" sheet (BAK-153) and
    /// create-from-unresolved-link (BAK-152). Selecting flushes any open note's
    /// save-on-switch (desired) and opens the new one. A failed write no longer
    /// navigates anywhere — staying put is calmer than opening a missing state.
    private func createNote(title: String, project: String, workingDirectory: String) {
        guard let rel = writeNote(title: title, project: project,
                                  workingDirectory: workingDirectory) else { return }
        selected = NoteRef(project: project, workingDirectory: workingDirectory, relativePath: rel)
    }

    /// Write→reindex WITHOUT selection — extracted (2b Task 7) because the slash
    /// menu's Sub-page command creates a note mid-typing, and navigating away from
    /// the note being edited would yank the caret out from under the user. The
    /// "+"-sheet and create-from-link flows layer selection back on via
    /// `createNote`. Returns the created relativePath, nil when the write fails.
    private func writeNote(title: String, project: String, workingDirectory: String) -> String? {
        let io = FileVaultIO(rootPath: workingDirectory)
        let rel = NoteCreation.relativePath(title: title, existing: io.notePaths())
        // write() creates the notes/ folder if absent (FileVaultIO, Task 1).
        do { try io.write(rel, NoteCreation.stub(title: title)) } catch { return nil }
        noteIndex.reindex(project: project, workingDirectory: workingDirectory)
        return rel
    }

    // MARK: - Rename / delete (polish pack E)

    /// Moves the file to the system Trash (Finder-recoverable — Mustard isn't
    /// git-backed yet, so this is the reversible delete). Inbound links dangle;
    /// they already offer create-from-link. No link rewrite on delete (spec).
    private func performDelete(_ target: DeleteTarget) {
        deleting = nil
        if selected == target.ref {
            // Unmount the open editor FIRST (same reasoning as performRename):
            // its onDisappear autosave writes to the note's path, and firing
            // AFTER the trash would quietly resurrect the file. The flush lands
            // before the async hop; trashing then removes the flushed file.
            selected = nil
            DispatchQueue.main.async { executeDelete(target) }
        } else {
            executeDelete(target)
        }
    }

    private func executeDelete(_ target: DeleteTarget) {
        let io = FileVaultIO(rootPath: target.ref.workingDirectory)
        try? io.trash(target.ref.relativePath)
        noteIndex.reindex(project: target.ref.project, workingDirectory: target.ref.workingDirectory)
    }

    /// Link-aware rename: `NoteRename.plan` computes the new path + retitled
    /// content + every inbound-link rewrite (from the index's contentSnapshots);
    /// `executeRename` applies it — snapshot-before-write for each touched file,
    /// mirroring the editor's save flow — then reindexes and follows the note.
    private func performRename(_ target: RenameTarget, newTitle: String) {
        renaming = nil
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != target.currentTitle else { return }
        if selected == target.ref {
            // The note is open — unmount its editor FIRST. onDisappear flushes any
            // dirty edits to the (still-)old path, so the rename transforms the
            // user's latest content, and a later save-on-switch can't write to the
            // old path and resurrect the file the rename just moved. The async hop
            // runs after the unmount transaction completes; `executeRename`
            // re-selects the new ref when done.
            selected = nil
            DispatchQueue.main.async { executeRename(target, newTitle: trimmed, reselect: true) }
        } else {
            executeRename(target, newTitle: trimmed, reselect: false)
        }
    }

    private func executeRename(_ target: RenameTarget, newTitle: String, reselect: Bool) {
        let io = FileVaultIO(rootPath: target.ref.workingDirectory)
        // Read LIVE files, never index snapshots — this vault has three writers
        // (Obsidian, the sweep agent, the connected worker) and the index refreshes
        // on a 300s tick, so a snapshot-based rewrite could clobber up to ~5 min
        // of external edits in every linking note (final-review #3). A rename is
        // rare; a whole-project read is cheap at that frequency.
        guard let oldContent = io.read(target.ref.relativePath) else { return }
        let projectEntries = entries.filter { $0.project == target.ref.project }
        let others: [(relativePath: String, content: String)] = projectEntries
            .filter { $0.relativePath != target.ref.relativePath }
            .compactMap { entry in
                io.read(entry.relativePath).map { (relativePath: entry.relativePath, content: $0) }
            }
        // Exclude self so a pure retitle of the same note can't collide-suffix.
        let existing = others.map(\.relativePath)
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
        } catch { return }   // partial failure leaves snapshots; the note stays put
        noteIndex.reindex(project: target.ref.project, workingDirectory: target.ref.workingDirectory)
        if reselect {
            selected = NoteRef(project: target.ref.project,
                               workingDirectory: target.ref.workingDirectory,
                               relativePath: plan.newRelativePath)
        }
    }

    /// Centered glyph + line — the calm empty-state pattern (Craft pass Phase 1).
    private func emptyState(_ message: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(message)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail (the note editor — BAK-150)

    @ViewBuilder
    private var detail: some View {
        if let selected {
            editor(for: selected)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("Select a note")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Builds the editor for the open note with a real wikilink resolver + tap
    /// handler (Task 9). The candidate-map build is hoisted ONCE here (per body
    /// evaluation) into `resolve`, mirroring BacklinksPanel — the per-tap `.map`
    /// on the tap path only runs on the rare click, so it stays cheap.
    private func editor(for selected: NoteRef) -> some View {
        let projectEntries = entries.filter { $0.project == selected.project }
        let resolve = WikilinkIndex.resolver(paths: projectEntries.map(\.relativePath))
        func ref(for path: String) -> NoteRef {
            NoteRef(project: selected.project, workingDirectory: selected.workingDirectory,
                    relativePath: path)
        }
        return NoteEditorView(
            ref: selected,
            entries: projectEntries,
            onNavigate: { self.selected = $0 },
            resolveWikilink: { target in resolve(target).map(ref(for:)) },
            onWikilinkTap: { target in
                // Setting `selected` flushes the editor's save-on-switch (onChange
                // of ref) before the .task reloads the target — same chain as the
                // sidebar and backlinks navigation.
                if let hit = resolve(target) {
                    self.selected = ref(for: hit)
                } else {
                    self.pendingWikilinkTarget = target
                }
            },
            // Autocomplete's Create row (polish pack D): write + reindex WITHOUT
            // navigating — same reasoning as the slash menu's Sub-page command
            // (yanking the caret mid-typing would be hostile). Returns the created
            // path so the splice can link by ITS stem (sanitization/collision).
            onCreateNote: { title in
                self.writeNote(title: title, project: selected.project,
                               workingDirectory: selected.workingDirectory)
            }
        )
        .alert(
            "Create note “\(pendingWikilinkTarget ?? "")”?",
            isPresented: Binding(
                get: { pendingWikilinkTarget != nil },
                set: { if !$0 { pendingWikilinkTarget = nil } }
            ),
            presenting: pendingWikilinkTarget
        ) { target in
            Button("Create") {
                // Create by the target's LAST path component: [[guides/Setup]] →
                // notes/Setup.md. Sanitizing the full target ("/" → "-") would
                // yield notes/guides-Setup.md, whose stem never satisfies the
                // link — dangling and re-offering creation forever. The resolver's
                // filename fallback (pinned in WikilinkIndexTests) guarantees the
                // created note satisfies the path-qualified link.
                createNote(title: ((target as NSString).lastPathComponent),
                           project: selected.project,
                           workingDirectory: selected.workingDirectory)
                pendingWikilinkTarget = nil
            }
            Button("Cancel", role: .cancel) { pendingWikilinkTarget = nil }
        } message: { target in
            Text("“\(target)” doesn't match any note in this project. Create it in notes/?")
        }
    }
}

/// The calm one-field title prompt (BAK-153; generalized for rename, polish pack E).
/// Kept a small dedicated view so `@FocusState` autofocuses the field on present;
/// return submits, Escape/Cancel dismisses.
private struct NewNoteSheet: View {
    let heading: String
    var confirmLabel = "Create"
    @Binding var title: String
    let onCancel: () -> Void
    let onCreate: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            TextField("Note title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($focused)
                .onSubmit(onCreate)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onCreate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.Palette.surface)
        .onAppear { focused = true }
    }
}
