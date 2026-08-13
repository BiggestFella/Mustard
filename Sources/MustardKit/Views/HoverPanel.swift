import AppKit
import SwiftUI
import SwiftData

/// Always-on-top, non-activating floating panel (spec §6b, first slice):
/// your current focus + the agent's state + waiting count. Never steals
/// focus; expands on hover; parked top-right by default, draggable anywhere.
@MainActor
public final class HoverPanel {
    private var panel: NSPanel?
    private let makeContent: () -> AnyView

    public init(content: @escaping () -> AnyView) {
        self.makeContent = content
    }

    public func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show()
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 264, height: 60),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hidesOnDeactivate = false
            installPanelContent(makeContent(), in: panel)
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 284, y: frame.maxY - 12))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

public struct HoverPanelView: View {
    @Environment(AgentService.self) private var agent
    @Query private var tasks: [MustardTask]
    @Query private var recommendations: [Recommendation]
    @State private var expanded = false

    public init() {}

    private var focusTask: MustardTask? {
        let todays = DayPlanner.tasksForDay(tasks, day: .now).filter { $0.stage.isOpen }
        return tasks.first { $0.stage == .inProgress } ?? todays.first
    }

    private var waitingCount: Int {
        RecommendationQueue.pending(recommendations, now: .now).count
            + tasks.filter { $0.stage == .needsReview }.count   // board review (ADR-0010)
    }

    private var upcoming: [MustardTask] {
        DayPlanner.upcoming(tasks, after: .now, limit: 3).filter { $0.id != focusTask?.id }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if agent.isExecuting {
                    ProgressView().controlSize(.small)
                    Text(agent.currentTitle ?? "Agent working…")
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                } else if let task = focusTask {
                    Image(systemName: "target")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(task.title)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "sun.max")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("Clear for now")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if waitingCount > 0 {
                    Text("\(waitingCount)")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.agent)
                }
            }
            if expanded {
                if let when = focusTask?.scheduledAt {
                    Text(when.formatted(date: .omitted, time: .shortened) + " · \(focusTask?.estimateMinutes ?? 30) min")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                if !upcoming.isEmpty {
                    Rectangle().fill(Theme.Palette.hairline).frame(height: 1).padding(.vertical, 2)
                    Text("NEXT UP")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.08)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    ForEach(upcoming) { task in
                        HStack(spacing: 8) {
                            Text(task.scheduledAt?.formatted(date: .omitted, time: .shortened) ?? "")
                                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.accent)
                                .frame(width: 52, alignment: .leading)
                            Text(task.title)
                                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text(waitingCount > 0 ? "\(waitingCount) waiting on you" : "Nothing waiting on you")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline))
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) { expanded = hovering }
        }
    }
}
