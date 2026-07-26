import SwiftUI
import SwiftData

/// Dedicated full-text note search (Notes polish pack B). Opened by ⌘⇧F and the ⌘K
/// "Search notes" command. Live results from the pure `NoteSearch` over the SwiftData
/// note index; ↑/↓ + Enter (or click) opens the note in the Notes surface via `onOpen`.
/// Presentation mirrors `CommandBarView` — a calm light panel over a dimmed scrim
/// (RootView owns the scrim + toggle, same as the ⌘K bar).
struct NoteSearchView: View {
    @Binding var isPresented: Bool
    let onOpen: (NoteRef) -> Void
    @Query private var entries: [NoteIndexEntry]
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    /// Enabled sources with a working directory — needed to turn a hit's project
    /// into the NoteRef the Notes surface selects by.
    private var workingDir: [String: String] {
        let sources = SourceSettingsStore.loadOrMigrate().sources
            .filter { $0.enabled && !$0.workingDirectory.isEmpty }
        return Dictionary(sources.map { ($0.project, $0.workingDirectory) },
                          uniquingKeysWith: { a, _ in a })
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Search all notes…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .focused($focused)
                    .onSubmit { open(at: selected) }
            }
            .padding(14)

            if !hits.isEmpty {
                Divider().overlay(Theme.Palette.hairline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            row(hit, isSelected: index == selected)
                                .onTapGesture { open(at: index) }
                                .onHover { if $0 { selected = index } }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider().overlay(Theme.Palette.hairline)
                Text("No notes match")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(14)
            }
        }
        .frame(width: 520)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(hits.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onExitCommand { isPresented = false }
    }

    private func row(_ hit: NoteSearchHit, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "doc.text")
                .font(Theme.Fonts.meta)
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let snippet = hit.snippet {
                    Text(snippet)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(hit.project)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.Palette.surface : .clear)
        .contentShape(Rectangle())
    }

    private func open(at index: Int) {
        let list = hits
        guard list.indices.contains(index),
              let dir = workingDir[list[index].project] else { return }
        onOpen(NoteRef(project: list[index].project, workingDirectory: dir,
                       relativePath: list[index].relativePath))
        isPresented = false
    }
}
