import AppKit
import SwiftUI
import SwiftData

/// The notch surface (spec §6a): a black, notch-hugging panel anchored to
/// whichever screen is active (external monitor preferred — see
/// `NotchScreenPicker`). Idle: thin strip rotating focus → waiting count.
/// Hover: expands into a triage summary card + today's agenda + quick
/// capture. Intentionally dark — it extends the physical notch — unlike
/// the rest of the app.
@MainActor
public final class NotchController {
    private var panel: NSPanel?
    private let makeContent: (_ controller: NotchController) -> AnyView

    /// Tested state machine (`NotchPinState`); the controller only feeds it
    /// events and applies the resulting geometry.
    private var pinState = NotchPinState()
    private var graceTimer: Timer?
    private var clickOutsideMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    /// The active tab drives the expanded frame (`NotchPanelMetrics`).
    public private(set) var activeTab: NotchTab = .today

    /// Set by the shell view so pin/tab changes re-render it.
    public var onStateChange: (() -> Void)?

    public init(content: @escaping (_ controller: NotchController) -> AnyView) {
        self.makeContent = content
    }

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var isPinned: Bool { pinState.isPinned }
    public var isExpanded: Bool { pinState.isExpanded }

    private var screen: NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: index,
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main
            )
        }
        guard let chosen = NotchScreenPicker.choose(from: descriptors),
              let index = chosen.id as? Int else { return NSScreen.main }
        return screens[index]
    }

    /// Idle strip geometry: hug the physical notch with a small lip below;
    /// sensible fallback for displays without a notch.
    private func idleFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        let width: CGFloat
        let height: CGFloat
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width + 24
            height = notchHeight + 20
        } else {
            width = 230
            height = 30
        }
        return NSRect(
            x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height
        )
    }

    /// Expanded geometry is per-tab (grid tabs are taller than list tabs).
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let size = NotchPanelMetrics.expandedSize(for: activeTab)
        let frame = screen.frame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// ⌘⇧N: open the panel *pinned*, or hide it (dropping the pin) if visible.
    public func toggle() {
        if let panel, panel.isVisible {
            graceTimer?.invalidate()
            graceTimer = nil
            // A hidden panel never receives a hover-exit, so record the pointer
            // as outside before unpinning — otherwise a peek would survive the
            // hide and the panel would re-open stuck expanded.
            pinState.hoverChanged(isInside: false, now: .now)
            unpin()
            panel.orderOut(nil)
            return
        }
        show()
        pin()
    }

    public func show() {
        guard let screen else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: idleFrame(on: screen),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.contentView = NSHostingView(rootView: makeContent(self))
            self.panel = panel
            // Follow display connect/disconnect: previously the panel only
            // re-resolved its screen on the next show()/hover, so unplugging an
            // external monitor left it stranded off-screen.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyFrame() }
            }
        }
        applyFrame()
        panel?.orderFrontRegardless()
    }

    // MARK: - Events from the shell view

    public func hoverChanged(_ isInside: Bool) {
        pinState.hoverChanged(isInside: isInside, now: .now)
        applyFrame()
        if !isInside { armGraceTimer() }
        onStateChange?()
    }

    public func pin() {
        pinState.pin()
        applyFrame()
        installClickOutsideMonitor()
        onStateChange?()
    }

    /// Esc / click-away / hide. Keeps a hover peek only while the pointer is in.
    public func unpin() {
        pinState.unpin()
        applyFrame()
        removeClickOutsideMonitor()
        onStateChange?()
    }

    public func select(tab: NotchTab) {
        activeTab = tab
        applyFrame()
        onStateChange?()
    }

    /// ⌘⇧N / ⌃⌥V entry: open pinned on a specific tab.
    public func openPinned(on tab: NotchTab) {
        // Set the tab before showing so the panel opens straight at that tab's
        // size rather than resizing a frame later.
        activeTab = tab
        show()
        pin()
    }

    // MARK: - Internals

    private func armGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(
            withTimeInterval: NotchPinState.collapseGrace + 0.05, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pinState.collapseIfDue(now: .now)
                self.applyFrame()
                self.onStateChange?()
            }
        }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pinState.isPinned else { return }
                // A global monitor only fires for clicks in OTHER apps/windows;
                // clicks inside our own panel never reach it — which is exactly
                // "click away to unpin".
                self.unpin()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }

    private func applyFrame() {
        guard let panel, let screen else { return }
        let expanded = pinState.isExpanded
        panel.hasShadow = expanded
        panel.setFrame(
            expanded ? expandedFrame(on: screen) : idleFrame(on: screen),
            display: true, animate: true)
    }
}

public struct NotchView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Environment(NotchNavigation.self) private var nav
    /// Optional: absent in previews/tests that don't wire the recorder.
    @Environment(MeetingCaptureCoordinator.self) private var meetingRecorder: MeetingCaptureCoordinator?
    @Query private var tasks: [MustardTask]
    @Query(sort: \Recommendation.createdAt, order: .reverse) private var recommendations: [Recommendation]
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]
    @State private var hovering = false
    /// Bumped from the controller's `onStateChange` so pin/tab changes (which
    /// live outside SwiftUI) re-evaluate this view.
    @State private var stateVersion = 0
    @State private var captureText = ""
    @FocusState private var captureFocused: Bool
    /// Handle for pin/tab/hover events; the controller outlives the view.
    let controller: NotchController?

    public init(controller: NotchController? = nil) {
        self.controller = controller
    }

    /// The panel is expanded on a hover peek OR whenever the controller says so
    /// (pinned, or still inside the collapse grace window).
    private var expanded: Bool {
        _ = stateVersion  // read so SwiftUI tracks controller-driven changes
        return hovering || (controller?.isExpanded ?? false)
    }

    private var focusTask: MustardTask? {
        let todays = DayPlanner.tasksForDay(tasks, day: .now).filter { $0.stage.isOpen && !$0.isBlocked }
        return tasks.first { $0.stage == .inProgress && !$0.isBlocked } ?? todays.first
    }

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }

    /// Tasks the board is waiting on you to review (output review now lives on the
    /// board's Needs Review column — ADR-0010).
    private var needsReviewCount: Int {
        tasks.filter { $0.stage == .needsReview }.count
    }

    private var waitingCount: Int {
        // Both agent attention stages count — a Needs You question waits on you just like a
        // Needs Review output (mirrors PersonalBoard.waitingCount / AgentInbox).
        pending.count + AgentInbox.attentionTaskCount(tasks)
    }

    private var nextMeeting: CalendarEvent? {
        events.first { $0.start > .now && Calendar.current.isDateInToday($0.start) }
    }

    private func nextMeetingLabel() -> String? {
        guard let m = nextMeeting else { return nil }
        return "\(m.title) · \(m.start.formatted(date: .omitted, time: .shortened))"
    }

    private var todayAgenda: [AgendaItem] {
        DayPlanner.agenda(tasks: tasks, events: events, day: .now)
    }

    private var todayProgress: (done: Int, total: Int) {
        DayPlanner.dayProgress(tasks, day: .now)
    }

    private var triageApprovals: Int { pending.count }
    private var triageReviews: Int { needsReviewCount }
    private var triageTotal: Int { triageApprovals + triageReviews }

    private var triageSubline: String {
        var parts: [String] = []
        if triageApprovals > 0 {
            parts.append("\(triageApprovals) approval\(triageApprovals == 1 ? "" : "s")")
        }
        if triageReviews > 0 {
            parts.append("\(triageReviews) review\(triageReviews == 1 ? "" : "s") waiting")
        }
        return parts.joined(separator: " · ")
    }

    private func toggleDone(_ task: MustardTask) {
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            TaskCompletion.complete(task, in: context)
        }
    }

    private func openDetail(_ item: AgendaItem) {
        if case .task(let task) = item.kind {
            nav.pendingTask = task
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            shape
            Spacer(minLength: 0)
        }
        .onHover { isIn in
            withAnimation(.snappy(duration: 0.16)) { hovering = isIn }
            controller?.hoverChanged(isIn)
        }
        .onAppear {
            controller?.onStateChange = {
                withAnimation(.snappy(duration: 0.16)) { stateVersion &+= 1 }
            }
        }
    }

    private func capture() {
        let trimmed = captureText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { captureFocused = true; return }
        context.insert(MustardTask(title: trimmed))
        captureText = ""
        captureFocused = true
    }

    private var shape: some View {
        Group {
            // Task 10 rebuilds this into the tabbed shell; for now `expanded`
            // just widens the hover trigger to include the pinned state.
            if expanded { expandedContent } else { idleContent }
        }
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: expanded ? 18 : 10,
                bottomTrailingRadius: expanded ? 18 : 10
            )
            .fill(.black)
        )
    }

    private var idleContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 4)) { timeline in
                // Prefer a starred focus task's title over the plain in-progress/next
                // fallback; when the agent is executing its work still wins the slot.
                let idleFocus = RitualPlanner.focusTitle(tasks, day: .now) ?? focusTask?.title
                // Same gate as the Today banner — read the ritual keys straight from
                // UserDefaults (0 == never → nil) since the notch has no @AppStorage.
                let last = UserDefaults.standard.double(forKey: RitualPrompt.lastPlannedKey)
                let dismissed = UserDefaults.standard.double(forKey: RitualPrompt.dismissedKey)
                let planPrompt = RitualPrompt.shouldOffer(
                    lastPlannedDay: last > 0 ? Date(timeIntervalSince1970: last) : nil,
                    dismissedDay: dismissed > 0 ? Date(timeIntervalSince1970: dismissed) : nil,
                    now: .now)
                let items = NotchTicker.idleItems(
                    focusTitle: agent.isExecuting ? (agent.currentTitle ?? "Agent working…") : idleFocus,
                    waitingCount: waitingCount,
                    nextEvent: nextMeetingLabel(),
                    planPrompt: planPrompt
                )
                let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 4)
                HStack(spacing: 5) {
                    // Persistent recording indicator (meeting recorder spec):
                    // visible for the whole recording, even on the idle strip.
                    if case .recording = meetingRecorder?.state {
                        Circle().fill(Color(hex: "#FF5F57")).frame(width: 5, height: 5)
                    }
                    if agent.isExecuting {
                        Circle().fill(Color(hex: "#7F77DD")).frame(width: 5, height: 5)
                    } else if waitingCount > 0 {
                        Circle().fill(Color(hex: "#5DCAA5")).frame(width: 5, height: 5)
                    }
                    Text(NotchTicker.item(items, tick: tick))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 30)

            Text("Agent")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            if triageTotal > 0 {
                triageCard
            }

            agendaSection

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            // Manual meeting recorder (Meetings Task 6): consent-gated
            // Start Meeting, live controls while recording.
            MeetingRecordingNotchView()

            captureBar
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var triageCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#AFA9EC"))
                .frame(width: 28, height: 28)
                .background(Color(hex: "#7F77DD").opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(triageTotal) item\(triageTotal == 1 ? "" : "s") to triage")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                Text(triageSubline)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button {
                nav.openAgentConsole = true
            } label: {
                HStack(spacing: 3) {
                    Text("Open")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "#AFA9EC"))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var agendaSection: some View {
        let items = todayAgenda
        let progress = todayProgress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY · \(Date.now.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.08)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if progress.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(Color(hex: "#5DCAA5"))
                            .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(max(progress.total, 1)))
                    }
                }
                .frame(height: 3)
            }
            if items.isEmpty {
                Text("Nothing scheduled today")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(items) { item in
                            AgendaRow(item: item, onToggleDone: toggleDone, onOpen: { openDetail(item) })
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private var captureBar: some View {
        HStack(spacing: 8) {
            TextField("Add to inbox…", text: $captureText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .focused($captureFocused)
                .onSubmit(capture)
            Button("Add", action: capture)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(hex: "#534AB7"), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 12)
    }
}

/// One row of the notch's TODAY agenda. Tasks toggle done via their status
/// circle and open `TaskDetailSheet` on row tap; events have no done state
/// or detail view — their circle is a static indicator and only "Join" is
/// interactive.
private struct AgendaRow: View {
    let item: AgendaItem
    var onToggleDone: (MustardTask) -> Void
    var onOpen: () -> Void

    private var timeLabel: String {
        guard let time = item.time else { return "Any" }
        return time.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 34, alignment: .leading)

            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white.opacity(0.9))
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                if let tag = item.tagLabel {
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: item.tagColorHex ?? "#B0ACA1"))
                }
            }
            Spacer(minLength: 0)
            if let joinURL = item.joinURL, let url = URL(string: joinURL) {
                Link("Join", destination: url)
                    .font(.system(size: 11)).foregroundStyle(Color(hex: "#6E9FFF"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.kind {
        case .task(let task):
            Button {
                onToggleDone(task)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? .white.opacity(0.3) : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
        case .event:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}
