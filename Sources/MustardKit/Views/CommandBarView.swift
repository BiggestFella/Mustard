import SwiftUI
import SwiftData

/// The ⌘K bar (spec §6c): capture and navigate without the mouse.
/// Calm light panel floating over the active screen.
struct CommandBarView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Environment(NoteIndexService.self) private var noteIndex
    @AppStorage("vaultPath") private var vaultPath = ""
    @Binding var isPresented: Bool
    @Binding var screen: MustardScreen
    /// Opens the full-text note search palette (polish pack B) — RootView owns its
    /// presentation, same as it owns this bar's.
    var onSearchNotes: () -> Void = {}
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var items: [CommandItem] { CommandBarEngine.items(query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Type a task, or search commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .focused($focused)
                    .onSubmit { execute(items[min(selected, items.count - 1)]) }
            }
            .padding(14)

            Divider().overlay(Theme.Palette.hairline)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(index == selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .frame(width: 18)
                    Text(item.title)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if index == selected {
                        Text("↩")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(index == selected ? Theme.Palette.surface : .clear)
                .contentShape(Rectangle())
                .onTapGesture { execute(item) }
                .onHover { if $0 { selected = index } }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 480)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, items.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onExitCommand { isPresented = false }
    }

    private func execute(_ item: CommandItem) {
        switch item.kind {
        case .addTask(let title):
            let task = MustardTask(title: title)
            if screen == .today {
                task.scheduledAt = Calendar.current.date(
                    bySettingHour: 9, minute: 0, second: 0, of: .now)
                PersonalBoard.normalizePlacement(task)
            }
            context.insert(task)
        case .planDay:
            // Today owns the ritual sheet state; the command bar can't reach it,
            // so route through the shared AppStorage flag TodayView consumes.
            screen = .today
            UserDefaults.standard.set(true, forKey: RitualPrompt.openRequestedKey)
        case .goToday:
            screen = .today
        case .goBoard:
            screen = .board
        case .goWeek:
            screen = .week
        case .goNotes:
            screen = .notes
        case .goAgent:
            screen = .agent
        case .sweep:
            Task { await agent.sweep(vaultPath: vaultPath) }
        case .reindexNotes:
            noteIndex.reindexAll(SourceSettingsStore.loadOrMigrate())
        case .searchNotes:
            onSearchNotes()
        }
        isPresented = false
    }
}
