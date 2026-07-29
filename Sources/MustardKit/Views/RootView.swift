import SwiftUI
import SwiftData
import AppKit

public enum MustardScreen: String, CaseIterable, Identifiable {
    case today = "Today"
    case board = "Board"
    case week = "Week"
    case notes = "Notes"
    case meetings = "Meetings"
    case agent = "Agent"
    case lists = "Lists"
    case settings = "Settings"
    case voiceSetup = "Voice Setup"
    public var id: String { rawValue }

    /// Screens shown as top-level sidebar buttons. `.lists` is intentionally
    /// excluded — it's reached by selecting an area/list/unfiled row below.
    /// `.voiceSetup` is reached from Settings (BAK-280).
    static let primary: [MustardScreen] = [.today, .board, .week, .notes, .meetings, .agent]

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .board: "rectangle.split.3x1"
        case .week: "calendar"
        case .notes: "doc.text"
        case .meetings: "mic"
        case .agent: "sparkles"
        case .lists: "tray.full"
        case .settings: "gearshape"
        case .voiceSetup: "waveform"
        }
    }
}

/// What the Lists screen is showing: a specific list, or the unfiled bucket.
enum ListScope: Equatable {
    case list(TaskList)
    case unfiled

    static func == (lhs: ListScope, rhs: ListScope) -> Bool {
        switch (lhs, rhs) {
        case (.unfiled, .unfiled): return true
        case let (.list(a), .list(b)): return a === b
        default: return false
        }
    }

    var isUnfiled: Bool { if case .unfiled = self { return true }; return false }
    var listValue: TaskList? { if case .list(let l) = self { return l }; return nil }
}

/// Root: a calm fixed sidebar (no toolbar chrome) and the active screen.
public struct RootView: View {
    @State private var screen: MustardScreen = .today
    @State private var selectedScope: ListScope?
    @State private var showCommandBar = false
    @State private var sourcePanel = SourcePanelController()
    @State private var selectedTaskFromNotch: MustardTask?
    @Environment(NotchNavigation.self) private var notchNav
    @Query private var recommendations: [Recommendation]
    @Query private var tasks: [MustardTask]

    public init() {}

    private var waitingCount: Int {
        // Shared with Today's nudge + the dock (BAK-104); respects snooze/ignore.
        AgentInbox.waitingCount(recommendations: recommendations, tasks: tasks)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.Palette.hairline)
            VStack(spacing: 0) {
                Group {
                    switch screen {
                    case .today: TodayView(onPlan: { screen = .agent })
                    case .board: BoardView()
                    case .week: WeekView()
                    case .notes: NotesView()
                    case .meetings: MeetingReviewView()
                    case .agent: AgentConsoleView()
                    case .lists: ListContentView(scope: selectedScope ?? .unfiled)
                    case .settings: SettingsView(onVoiceSetup: { screen = .voiceSetup })
                    case .voiceSetup: VoiceSetupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if screen != .agent && screen != .settings && screen != .voiceSetup { copilotDock }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.bg)
        .overlay {
            if showCommandBar {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { showCommandBar = false }
                    CommandBarView(isPresented: $showCommandBar, screen: $screen)
                        .padding(.top, 90)
                }
            }
        }
        .background {
            Group {
                // Hidden trigger: ⌘K opens the command bar while the window is key.
                Button("") { showCommandBar.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                // Hidden trigger: ⌘⇧S toggles the source inspector.
                Button("") { sourcePanel.isPresented.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .opacity(0)
        }
        .inspector(isPresented: $sourcePanel.isPresented) {
            SourcePanelView()
                .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
        }
        .environment(sourcePanel)
        // Locked light design (ADR-0005); pin appearance so native controls
        // (TextEditor, DatePicker, pickers) don't render dark under macOS dark mode.
        // The notch is a separate panel with its own explicit dark colors — unaffected.
        .preferredColorScheme(.light)
        .taskDetailDrawer(item: $selectedTaskFromNotch)
        .onChange(of: notchNav.pendingTask, initial: true) { _, task in
            guard let task else { return }
            NSApp.activate(ignoringOtherApps: true)
            selectedTaskFromNotch = task
            notchNav.pendingTask = nil
        }
        .onChange(of: notchNav.openAgentConsole, initial: true) { _, shouldOpen in
            guard shouldOpen else { return }
            NSApp.activate(ignoringOtherApps: true)
            screen = .agent
            notchNav.openAgentConsole = false
        }
    }

    /// Persistent agent co-pilot dock (BAK-106): shown on every screen except the Agent
    /// console; surfaces what's waiting and links into the console.
    private var copilotDock: some View {
        let recs = AgentInbox.pendingRecCount(recommendations)
        let items = AgentInbox.attentionTaskCount(tasks)
        return VStack(spacing: 0) {
            Divider().overlay(Theme.Palette.hairline)
            HStack(spacing: 8) {
                Circle().fill(Theme.Palette.agent).frame(width: 7, height: 7)
                Text("Agent")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.agentText)
                Text(AgentInbox.dockText(recs: recs, items: items))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: 0)
                Button("Open console →") { screen = .agent }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.agentText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Theme.Palette.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mustard")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.bottom, 16)
            ForEach(MustardScreen.primary) { item in
                Button {
                    screen = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(Theme.Fonts.meta)
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(Theme.Fonts.body)
                        Spacer()
                        if item == .agent && waitingCount > 0 {
                            Text("\(waitingCount)")
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(Theme.Palette.agent)
                        }
                    }
                    .foregroundStyle(screen == item ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        screen == item ? Theme.Palette.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            AreaSidebarSection(screen: $screen, selectedScope: $selectedScope)

            Spacer()

            // Settings pinned at the bottom (BAK-133).
            Button { screen = .settings } label: {
                HStack(spacing: 8) {
                    Image(systemName: MustardScreen.settings.systemImage)
                        .font(Theme.Fonts.meta).frame(width: 16)
                    Text("Settings").font(Theme.Fonts.body)
                    Spacer()
                }
                .foregroundStyle(screen == .settings ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(screen == .settings ? Theme.Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 168, alignment: .leading)
        .background(Theme.Palette.bg)
    }
}
